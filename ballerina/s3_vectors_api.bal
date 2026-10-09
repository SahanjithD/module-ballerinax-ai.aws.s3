// Copyright (c) 2026, WSO2 LLC. (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/ai;
import ballerina/http;
import ballerina/lang.runtime;
import ballerina/log;
import ballerina/random;
import ballerinax/aws;
import ballerinax/aws.auth;

// The S3 Vectors wire protocol: signed `POST /{Operation}` calls with JSON bodies. S3 Vectors has
// no Ballerina connector, so requests are signed here with `ballerinax/aws.auth`.

final readonly & int[] RETRYABLE_STATUS_CODES = [408, 429, 500, 503];

// Kept short: each retry re-signs, so a long backoff buys nothing.
const int MAX_ATTEMPTS = 3;
const decimal RETRY_BASE_DELAY_SECONDS = 2.0d;
const decimal RETRY_MAX_DELAY_SECONDS = 15.0d;

// Returns the endpoint URL and the bare host for the SigV4 `host` header. S3 Vectors only has
// dual-stack endpoints (`s3vectors.{region}.api.aws`), so `dualstack` is forced on. AWS defines a
// FIPS hostname but hasn't deployed it, so `fips` is rejected.
isolated function resolveServiceEndpoint(VectorStoreConnectionConfig config) returns [string, string]|ai:Error {
    aws:EndpointConfig endpointConfig = config?.endpoint ?: {};
    if endpointConfig.fips {
        return error ai:Error(
            "Amazon S3 Vectors publishes no FIPS endpoint in any region, so 'endpoint.fips' cannot " +
            "be enabled: the host it would target, 's3vectors-fips.{region}.api.aws', does not exist. " +
            "If a FIPS-validated path is mandatory for this workload, S3 Vectors cannot provide one " +
            "itself — terminate FIPS in front of the service and point 'endpoint.customEndpoint' at " +
            "that endpoint");
    }

    aws:EndpointConfig resolverConfig = {dualstack: true, fips: false};
    string? customEndpoint = endpointConfig.customEndpoint;
    if customEndpoint is string {
        resolverConfig.customEndpoint = customEndpoint;
    }
    string url = aws:resolveEndpoint("s3vectors", config.region, resolverConfig);
    // The SigV4 `host` header takes `host[:port]` only, without any path.
    string host = aws:resolveEndpointHost("s3vectors", config.region, resolverConfig);
    int? slashIndex = host.indexOf("/");
    return [url, slashIndex is int ? host.substring(0, slashIndex) : host];
}

// S3 Vectors rejects HTTP/2 and chunked bodies (a SigV4 body needs a Content-Length), so both
// are pinned, as in the AWS SDKs. Transport retries stay off because `invoke` retries itself.
isolated function toClientConfiguration(HttpConfig config) returns http:ClientConfiguration {
    return {
        httpVersion: http:HTTP_1_1,
        http1Settings: {chunking: http:CHUNKING_NEVER},
        timeout: config.timeout,
        proxy: config?.proxy,
        secureSocket: config?.secureSocket,
        poolConfig: config?.poolConfig,
        circuitBreaker: config?.circuitBreaker,
        socketConfig: config.socketConfig,
        responseLimits: config.responseLimits
    };
}

// Stops a provider's background refresh (assume-role, SSO) when `VectorStore.init` fails.
isolated function closeCredentialProvider(auth:CredentialProvider provider) {
    error? result = provider.close();
    if result is error {
        log:printDebug("Failed to close the AWS credential provider", 'error = result);
    }
}

// Signs and sends one operation, re-signing on each retry. Returns the JSON body, `{}` when empty.
isolated function invoke(http:Client httpClient, auth:CredentialProvider provider, string host,
        aws:Region|string region, string operation, json payload) returns json|ai:Error {
    byte[] body = payload.toJsonString().toBytes();
    string path = "/" + operation;

    error? lastError = ();
    foreach int attempt in 1 ... MAX_ATTEMPTS {
        auth:Credentials|auth:CredentialResolutionError creds = provider.getCredentials();
        if creds is auth:CredentialResolutionError {
            return error ai:Error(
                string `Failed to resolve AWS credentials for the '${operation}' request to S3 Vectors: ` +
                creds.message(), creds);
        }

        map<string>|auth:SigningError signed = auth:getSignedHeaders({
            method: "POST",
            host,
            path,
            headers: {"content-type": "application/json"},
            payload: body
        }, creds, region, "s3vectors");
        if signed is auth:SigningError {
            return error ai:Error(
                string `Failed to sign the '${operation}' request to S3 Vectors: ${signed.message()}`, signed);
        }

        http:Request request = new;
        request.setBinaryPayload(body, contentType = "application/json");
        foreach [string, string] [headerName, headerValue] in signed.entries() {
            request.setHeader(headerName, headerValue);
        }

        http:Response|http:ClientError response = httpClient->post(path, request);
        if response is http:ClientError {
            lastError = response;
            // A TLS failure won't fix itself on retry.
            if attempt < MAX_ATTEMPTS && response !is http:SslError {
                runtime:sleep(backoffDelay(attempt));
                continue;
            }
            return error ai:Error(
                string `Failed to call the S3 Vectors '${operation}' operation after ${attempt} attempt(s): ` +
                response.message(), response);
        }

        int statusCode = response.statusCode;
        if statusCode >= 200 && statusCode < 300 {
            json|http:ClientError responsePayload = response.getJsonPayload();
            if responsePayload is http:ClientError {
                // PutVectors and DeleteVectors succeed with an empty body.
                return {};
            }
            return responsePayload;
        }

        if isRetryableStatus(statusCode) && attempt < MAX_ATTEMPTS {
            runtime:sleep(backoffDelay(attempt));
            continue;
        }
        return mapErrorResponse(operation, statusCode, response, payload);
    }
    return error ai:Error(
        string `Failed to call the S3 Vectors '${operation}' operation`, lastError ?: error("unknown failure"));
}

isolated function isRetryableStatus(int statusCode) returns boolean {
    return RETRYABLE_STATUS_CODES.indexOf(statusCode) is int;
}

isolated function backoffDelay(int attempt) returns decimal {
    return withJitter(backoffCeiling(attempt));
}

// The base delay doubled per attempt, capped at the maximum.
isolated function backoffCeiling(int attempt) returns decimal {
    int multiplier = 1;
    foreach int _ in 1 ..< attempt {
        multiplier *= 2;
    }
    decimal delay = RETRY_BASE_DELAY_SECONDS * <decimal>multiplier;
    return delay < RETRY_MAX_DELAY_SECONDS ? delay : RETRY_MAX_DELAY_SECONDS;
}

// Somewhere between half and all of the ceiling, so throttled clients don't retry in lockstep.
isolated function withJitter(decimal ceiling) returns decimal {
    decimal half = ceiling / 2d;
    return half + half * <decimal>random:createDecimal();
}

// Names the index a request targeted, for error messages.
isolated function describeTarget(json requestPayload) returns string {
    if requestPayload !is map<json> {
        return "the target index";
    }
    json|error indexArn = requestPayload.indexArn;
    if indexArn is string {
        return string `index ARN '${indexArn}'`;
    }
    json|error vectorBucketName = requestPayload.vectorBucketName;
    json|error indexName = requestPayload.indexName;
    if vectorBucketName is string && indexName is string {
        return string `vector bucket '${vectorBucketName}', index '${indexName}'`;
    }
    return "the target index";
}

// Field names match `aws:ErrorDetails`.
isolated function serviceError(string message, int statusCode, string statusText, string? errorCode,
        string? errorMessage, string? requestId, error? cause = ()) returns ai:Error {
    return error ai:Error(message, cause, httpStatusCode = statusCode, httpStatusText = statusText,
            errorCode = errorCode, errorMessage = errorMessage, requestId = requestId);
}

// Adds context to a failure while keeping its response details reachable without `cause()`.
isolated function wrapServiceError(string message, ai:Error cause) returns ai:Error {
    map<anydata> detail = {};
    foreach [string, anydata|readonly] [key, value] in cause.detail().entries() {
        if value is anydata {
            detail[key] = value;
        }
    }
    int? statusCode = detail["httpStatusCode"] is int ? <int>detail["httpStatusCode"] : ();
    if statusCode is () {
        return error ai:Error(message, cause);
    }
    return serviceError(message, statusCode, stringDetail(detail, "httpStatusText") ?: "",
            stringDetail(detail, "errorCode"), stringDetail(detail, "errorMessage"),
            stringDetail(detail, "requestId"), cause);
}

isolated function stringDetail(map<anydata> detail, string key) returns string? {
    anydata value = detail[key];
    return value is string ? value : ();
}

// Maps a non-2xx response to an `ai:Error`, adding the likely fix where AWS's message doesn't.
isolated function mapErrorResponse(string operation, int statusCode, http:Response response, json requestPayload)
        returns ai:Error {
    string errorType = "";
    string|http:HeaderNotFoundError typeHeader = response.getHeader("x-amzn-errortype");
    if typeHeader is string {
        // The header may carry a request-id suffix (`ValidationException:abc123`).
        int? colonIndex = typeHeader.indexOf(":");
        errorType = colonIndex is int ? typeHeader.substring(0, colonIndex) : typeHeader;
    }

    // Only in this header, and the first thing AWS support asks for.
    string requestId = "";
    string|http:HeaderNotFoundError requestIdHeader = response.getHeader("x-amzn-requestid");
    if requestIdHeader is string {
        requestId = requestIdHeader;
    }

    string awsMessage = "";
    ValidationExceptionField[] fieldList = [];
    json|http:ClientError responsePayload = response.getJsonPayload();
    if responsePayload is json {
        ErrorResponse|error errorBody = responsePayload.cloneWithType(ErrorResponse);
        if errorBody is ErrorResponse {
            awsMessage = errorBody.message ?: "";
            fieldList = errorBody.fieldList ?: [];
            if errorType == "" {
                string? bodyType = errorBody.__type;
                if bodyType is string {
                    // May be a full shape ID (`#ValidationException`).
                    int? hashIndex = bodyType.lastIndexOf("#");
                    errorType = hashIndex is int ? bodyType.substring(hashIndex + 1) : bodyType;
                }
            }
        }
    }

    string detail = awsMessage == "" ? string `HTTP ${statusCode}` : string `HTTP ${statusCode}: ${awsMessage}`;
    string statusText = response.reasonPhrase;
    string target = describeTarget(requestPayload);

    string message;
    if statusCode == 403 {
        message = string `Access denied calling S3 Vectors '${operation}' on ${target} (${detail}). ` +
            string `Check that the caller has 's3vectors:${operation}' on the index.`;
        if operation == "QueryVectors" || operation == "ListVectors" {
            // Metadata or a filter also needs GetVectors, the most common cause of a 403 here.
            message += " Returning metadata or filtering also requires 's3vectors:GetVectors'.";
        }
    } else if statusCode == 404 {
        message =
            string `S3 Vectors '${operation}' failed: ${target} was not found (${detail}). Also confirm S3 ` +
            "Vectors is available in the configured region — it is not offered in every AWS region.";
    } else if statusCode == 400 && errorType == "ValidationException" && fieldList.length() > 0 {
        string[] fieldMessages = from ValidationExceptionField 'field in fieldList
            select string `'${'field.path}': ${'field.message}`;
        message = string `S3 Vectors '${operation}' rejected the request: ${", ".'join(...fieldMessages)}`;
    } else if statusCode == 400 && errorType == "ValidationException" {
        message = string `S3 Vectors '${operation}' rejected the request (${detail})`;
    } else if statusCode == 400 && errorType.startsWith("Kms") {
        message =
            string `S3 Vectors '${operation}' failed due to the vector bucket's encryption configuration ` +
            string `(${errorType}, ${detail}). Check the bucket's KMS key state and permissions.`;
    } else if statusCode == 402 {
        message =
            string `S3 Vectors '${operation}' failed: a service quota was exceeded (${detail}). See the ` +
            "S3 Vectors limits (vectors per index, metadata size, request rate) in the AWS documentation.";
    } else if isRetryableStatus(statusCode) {
        message =
            string `S3 Vectors '${operation}' failed after ${MAX_ATTEMPTS} attempts (${detail}). ` +
            "This is a retryable condition (timeout, throttling, or a transient server error); the " +
            "configured retries were exhausted.";
    } else {
        message = string `S3 Vectors '${operation}' failed (${detail})`;
    }
    return serviceError(message, statusCode, statusText, errorType == "" ? () : errorType,
            awsMessage == "" ? () : awsMessage, requestId == "" ? () : requestId);
}

// Every data-plane operation takes either `indexArn`, or `vectorBucketName` and `indexName`.
isolated function withIndexIdentifier(map<json> body, VectorIndex index) returns map<json> {
    string? indexArn = index.indexArn;
    if indexArn is string {
        body["indexArn"] = indexArn;
        return body;
    }
    body["vectorBucketName"] = index.vectorBucketName;
    body["indexName"] = index.indexName;
    return body;
}

isolated function getIndex(http:Client httpClient, auth:CredentialProvider provider, string host,
        aws:Region|string region, VectorIndex index) returns IndexAttributes|ai:Error {
    json body = withIndexIdentifier({}, index);
    json response = check invoke(httpClient, provider, host, region, "GetIndex", body);
    GetIndexResponse|error result = response.cloneWithType(GetIndexResponse);
    if result is error {
        return error ai:Error(
            "Failed to parse the S3 Vectors GetIndex response: " + result.message(), result);
    }
    return result.index;
}

// The caller keeps each batch within the 500-vector and 20 MiB limits.
isolated function putVectors(http:Client httpClient, auth:CredentialProvider provider, string host,
        aws:Region|string region, VectorIndex index, json[] vectors) returns ai:Error? {
    json body = withIndexIdentifier({"vectors": vectors}, index);
    _ = check invoke(httpClient, provider, host, region, "PutVectors", body);
}

isolated function deleteVectors(http:Client httpClient, auth:CredentialProvider provider, string host,
        aws:Region|string region, VectorIndex index, string[] keys) returns ai:Error? {
    json body = withIndexIdentifier({"keys": keys}, index);
    _ = check invoke(httpClient, provider, host, region, "DeleteVectors", body);
}

// One page of results; the caller resends the same query with `nextToken` for the next.
isolated function queryVectors(http:Client httpClient, auth:CredentialProvider provider, string host,
        aws:Region|string region, VectorIndex index, json queryVector, int topK, json filter,
        QueryMode? queryMode, string? nextToken) returns QueryVectorsResponse|ai:Error {
    map<json> body = {
        "queryVector": queryVector,
        topK,
        "returnMetadata": true,
        "returnDistance": true
    };
    if filter !is () {
        body["filter"] = filter;
    }
    // Unset means the index's own mode; AWS rejects `CLASSIC` on an `ENHANCED` index.
    if queryMode is QueryMode {
        body["queryMode"] = queryMode;
    }
    if nextToken is string {
        body["nextToken"] = nextToken;
    }
    json response = check invoke(httpClient, provider, host, region, "QueryVectors", withIndexIdentifier(body, index));
    QueryVectorsResponse|error result = response.cloneWithType(QueryVectorsResponse);
    if result is error {
        return error ai:Error(
            "Failed to parse the S3 Vectors QueryVectors response: " + result.message(), result);
    }
    return result;
}

// One page of an index walk, used when a query has no embedding.
isolated function listVectors(http:Client httpClient, auth:CredentialProvider provider, string host,
        aws:Region|string region, VectorIndex index, int maxResults, boolean returnData, string? nextToken)
        returns ListVectorsResponse|ai:Error {
    map<json> body = {
        "maxResults": maxResults,
        "returnMetadata": true,
        "returnData": returnData
    };
    if nextToken is string {
        body["nextToken"] = nextToken;
    }
    json response = check invoke(httpClient, provider, host, region, "ListVectors", withIndexIdentifier(body, index));
    ListVectorsResponse|error result = response.cloneWithType(ListVectorsResponse);
    if result is error {
        return error ai:Error(
            "Failed to parse the S3 Vectors ListVectors response: " + result.message(), result);
    }
    return result;
}

// The caller batches keys at the 100-per-call limit.
isolated function getVectors(http:Client httpClient, auth:CredentialProvider provider, string host,
        aws:Region|string region, VectorIndex index, string[] keys) returns GetVectorsResponse|ai:Error {
    map<json> body = {"keys": keys, "returnData": true};
    json response = check invoke(httpClient, provider, host, region, "GetVectors", withIndexIdentifier(body, index));
    GetVectorsResponse|error result = response.cloneWithType(GetVectorsResponse);
    if result is error {
        return error ai:Error(
            "Failed to parse the S3 Vectors GetVectors response: " + result.message(), result);
    }
    return result;
}
