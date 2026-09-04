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
import ballerinax/aws;
import ballerinax/aws.auth;

// Everything that touches the S3 Vectors wire protocol lives here, so `vector_store.bal` deals
// only in normalized wire records and never signs a request or inspects a status code directly.
//
// S3 Vectors has no Ballerina connector (unlike `ballerinax/aws.s3` for object storage), so every
// operation is a hand-signed `POST /{OperationName}` call: `rest-json` protocol, SigV4 signing
// name "s3vectors", a JSON body on every request, and a JSON body (at minimum `{}`) on every
// 200 response.

// HTTP statuses worth retrying: request timeout, throttling, and transient server failures.
final readonly & int[] RETRYABLE_STATUS_CODES = [408, 429, 500, 503];

// Retry budget. Kept deliberately short: each retry re-signs the request (see `invoke`), and a
// SigV4 signature is only valid for a few minutes of clock skew, so there is no benefit to a
// long backoff schedule here the way there might be for an unsigned call.
const int MAX_ATTEMPTS = 3;
const decimal RETRY_BASE_DELAY_SECONDS = 2.0d;
const decimal RETRY_MAX_DELAY_SECONDS = 15.0d;

// Resolves the S3 Vectors endpoint for a connection config, returning both the full URL (for the
// `http:Client`) and the bare host (for the SigV4 `host` header, which must carry no scheme).
// Both come from `ballerinax/aws`'s resolver, so a `customEndpoint` override and the partition
// DNS suffixes are handled exactly as they are for `ballerinax/aws.s3`.
//
// `s3vectors` is absent from the endpoint metadata bundled with `ballerinax/aws`, so an
// unqualified resolve falls through to the wrong, non-existent host
// `s3vectors.{region}.amazonaws.com`. AWS's own endpoint rule set for this service resolves the
// host from the partition's dualstack DNS suffix unconditionally — there is no non-dualstack
// variant — so `dualstack: true` is forced here rather than passed through from the caller.
// Verified against the service's bundled endpoint-rule-set and empirically against the SDK: the
// correct host is `s3vectors.{region}.api.aws`.
//
// That rule set also defines a `s3vectors-fips.{region}.api.aws` variant, but AWS has not
// deployed it: the name does not resolve in any region, GovCloud included, while the equivalent
// `s3-fips.{region}.amazonaws.com` for S3 proper does. A FIPS request would therefore fail on DNS
// somewhere well downstream of the mistake, so `fips: true` is refused here instead.
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

    // `fips` is pinned false rather than passed through: the only accepted value is false, and
    // the guard above has already rejected the alternative.
    aws:EndpointConfig resolverConfig = {dualstack: true, fips: false};
    string? customEndpoint = endpointConfig.customEndpoint;
    if customEndpoint is string {
        resolverConfig.customEndpoint = customEndpoint;
    }
    string url = aws:resolveEndpoint("s3vectors", config.region, resolverConfig);
    // `resolveEndpointHost` strips the scheme but keeps any path a `customEndpoint` carries;
    // the SigV4 `host` header takes `host[:port]` only.
    string host = aws:resolveEndpointHost("s3vectors", config.region, resolverConfig);
    int? slashIndex = host.indexOf("/");
    return [url, slashIndex is int ? host.substring(0, slashIndex) : host];
}

// Signs and sends one S3 Vectors operation, retrying transient failures with a fresh signature
// on every attempt. Returns the parsed JSON body (`{}` for an operation with no output fields),
// or a typed `ai:Error` mapped from the response.
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
            if attempt < MAX_ATTEMPTS {
                runtime:sleep(backoffDelay(attempt));
                continue;
            }
            return error ai:Error(
                string `Failed to call the S3 Vectors '${operation}' operation after ${MAX_ATTEMPTS} attempts: ` +
                response.message(), response);
        }

        int statusCode = response.statusCode;
        if statusCode >= 200 && statusCode < 300 {
            json|http:ClientError responsePayload = response.getJsonPayload();
            if responsePayload is http:ClientError {
                // A 2xx response with no body (or a non-JSON body) is treated as an empty
                // result — every S3 Vectors success response is documented as JSON, but an
                // operation with no output fields (PutVectors, DeleteVectors) may legitimately
                // send an empty body.
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
    // Unreachable: the loop above always returns before exhausting its range. Kept only to
    // satisfy the compiler's flow analysis.
    return error ai:Error(
        string `Failed to call the S3 Vectors '${operation}' operation`, lastError ?: error("unknown failure"));
}

isolated function isRetryableStatus(int statusCode) returns boolean {
    return RETRYABLE_STATUS_CODES.indexOf(statusCode) is int;
}

// Exponential backoff with a low ceiling, per the comment on `MAX_ATTEMPTS`: retries here exist
// to smooth over throttling and transient failures, not to ride out a long outage.
isolated function backoffDelay(int attempt) returns decimal {
    // Ballerina has no exponentiation operator; double a multiplier `attempt - 1` times
    // instead (attempt 1 -> x1, attempt 2 -> x2, attempt 3 -> x4, ...).
    int multiplier = 1;
    foreach int _ in 1 ..< attempt {
        multiplier *= 2;
    }
    decimal delay = RETRY_BASE_DELAY_SECONDS * <decimal>multiplier;
    return delay < RETRY_MAX_DELAY_SECONDS ? delay : RETRY_MAX_DELAY_SECONDS;
}

// Describes the index identifier a request targeted, for error messages. `requestPayload` is
// whatever `invoke` sent — already carrying the fields `withIndexIdentifier` merged in — so this
// reads them back out rather than requiring every operation function to pass the identifier
// through separately.
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

// Attaches the details of a failed S3 Vectors response to the error as detail fields.
//
// `ai:Error`'s detail type is the open `error:Detail`, so these ride along on a plain `ai:Error`
// without a distinct error type of our own — the same mechanism the loader's `recoverableInWalk`
// flag uses. Field names match `aws:ErrorDetails`. A value the response did not carry is passed
// as `()`, which reads back identically to an absent key.
isolated function serviceError(string message, int statusCode, string statusText, string? errorCode,
        string? errorMessage, string? requestId, error? cause = ()) returns ai:Error {
    return error ai:Error(message, cause, httpStatusCode = statusCode, httpStatusText = statusText,
            errorCode = errorCode, errorMessage = errorMessage, requestId = requestId);
}

// Re-raises a failure under a message that adds the caller's own context — how far a batched
// operation got before it failed, say — carrying any response details forward. A plain wrapper
// would leave the status, error code and request id reachable only by walking `cause()`.
isolated function wrapServiceError(string message, ai:Error cause) returns ai:Error {
    map<anydata> detail = {};
    foreach [string, anydata|readonly] [key, value] in cause.detail().entries() {
        if value is anydata {
            detail[key] = value;
        }
    }
    int? statusCode = detail["httpStatusCode"] is int ? <int>detail["httpStatusCode"] : ();
    if statusCode is () {
        // Not a failure carrying response details (a pre-response failure, or an error raised by
        // this module's own validation), so there is nothing to carry forward.
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

// Maps a non-2xx S3 Vectors response to an `ai:Error`, naming the likely fix where AWS's own
// message would otherwise leave the caller guessing, and carrying the response's status, error
// code, message and request id as detail fields.
isolated function mapErrorResponse(string operation, int statusCode, http:Response response, json requestPayload)
        returns ai:Error {
    string errorType = "";
    string|http:HeaderNotFoundError typeHeader = response.getHeader("x-amzn-errortype");
    if typeHeader is string {
        // The header may carry a request-id suffix (`ValidationException:abc123`); keep only
        // the type.
        int? colonIndex = typeHeader.indexOf(":");
        errorType = colonIndex is int ? typeHeader.substring(0, colonIndex) : typeHeader;
    }

    // The request id is what AWS support asks for first, and it appears nowhere in the response
    // body — only in this header.
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
                    // `__type` may be a full shape ID (`#ValidationException`); keep the
                    // trailing segment.
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
        message =
            string `Access denied calling S3 Vectors '${operation}' on ${target} (${detail}). Metadata and ` +
            "metadata filters on QueryVectors/ListVectors additionally require the 's3vectors:GetVectors' " +
            "permission on top of the operation's own permission — this is the most common cause of a " +
            "403 here. Verify the caller has PutVectors, QueryVectors, GetVectors, DeleteVectors, " +
            "ListVectors, and GetIndex on the target index.";
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

// Merges the target index identifier into a request body, following the exactly-one-of contract
// every S3 Vectors data-plane operation shares: `indexArn` alone, or `vectorBucketName` +
// `indexName` together.
isolated function withIndexIdentifier(map<json> body, IndexIdentifier index) returns map<json> {
    string? indexArn = index.indexArn;
    if indexArn is string {
        body["indexArn"] = indexArn;
        return body;
    }
    body["vectorBucketName"] = index.vectorBucketName;
    body["indexName"] = index.indexName;
    return body;
}

// `GetIndex` — read back the immutable attributes (dimension, distance metric, non-filterable
// metadata keys) of the target index.
isolated function getIndex(http:Client httpClient, auth:CredentialProvider provider, string host,
        aws:Region|string region, IndexIdentifier index) returns IndexAttributes|ai:Error {
    json body = withIndexIdentifier({}, index);
    json response = check invoke(httpClient, provider, host, region, "GetIndex", body);
    GetIndexResponse|error result = response.cloneWithType(GetIndexResponse);
    if result is error {
        return error ai:Error(
            "Failed to parse the S3 Vectors GetIndex response: " + result.message(), result);
    }
    return result.index;
}

// `PutVectors` — upserts a batch of vectors. The caller (`vector_store.bal`) is responsible for
// keeping each batch within the 500-vector / 20 MiB request limits.
isolated function putVectors(http:Client httpClient, auth:CredentialProvider provider, string host,
        aws:Region|string region, IndexIdentifier index, json[] vectors) returns ai:Error? {
    json body = withIndexIdentifier({"vectors": vectors}, index);
    _ = check invoke(httpClient, provider, host, region, "PutVectors", body);
}

// `DeleteVectors` — deletes a batch of vectors by key. Idempotent: a key that does not exist is
// not an error.
isolated function deleteVectors(http:Client httpClient, auth:CredentialProvider provider, string host,
        aws:Region|string region, IndexIdentifier index, string[] keys) returns ai:Error? {
    json body = withIndexIdentifier({"keys": keys}, index);
    _ = check invoke(httpClient, provider, host, region, "DeleteVectors", body);
}

// `QueryVectors` — one page of an approximate nearest-neighbour search. `nextToken` is `()` for
// the first page; the caller loops on the returned `nextToken` until it is absent or `topK` is
// satisfied, re-sending the same `queryVector`/`topK`/`filter` each time, per AWS's pagination
// contract for this operation.
isolated function queryVectors(http:Client httpClient, auth:CredentialProvider provider, string host,
        aws:Region|string region, IndexIdentifier index, json queryVector, int topK, json filter,
        string? nextToken) returns QueryVectorsResponse|ai:Error {
    map<json> body = {
        "queryVector": queryVector,
        topK,
        "returnMetadata": true,
        "returnDistance": true
    };
    // `json` already includes `()`, so `filter` uses that directly to mean "no filter" rather
    // than a redundant `json?` — the field is omitted from the request rather than sent as
    // JSON null, which S3 Vectors would otherwise have to reject.
    if filter !is () {
        body["filter"] = filter;
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

// `ListVectors` — one page of an unfiltered index walk, used for the filter-only query path and
// for `deleteByFilter` support. `returnData` is left off; only metadata is needed to evaluate
// filters and collect keys.
isolated function listVectors(http:Client httpClient, auth:CredentialProvider provider, string host,
        aws:Region|string region, IndexIdentifier index, int maxResults, string? nextToken)
        returns ListVectorsResponse|ai:Error {
    map<json> body = {
        "maxResults": maxResults,
        "returnMetadata": true
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

// `GetVectors` — used only to hydrate `ai:VectorMatch.embedding` when `returnVectorData` is on.
// The caller batches keys at the 100-per-call limit.
isolated function getVectors(http:Client httpClient, auth:CredentialProvider provider, string host,
        aws:Region|string region, IndexIdentifier index, string[] keys) returns GetVectorsResponse|ai:Error {
    map<json> body = {"keys": keys, "returnData": true};
    json response = check invoke(httpClient, provider, host, region, "GetVectors", withIndexIdentifier(body, index));
    GetVectorsResponse|error result = response.cloneWithType(GetVectorsResponse);
    if result is error {
        return error ai:Error(
            "Failed to parse the S3 Vectors GetVectors response: " + result.message(), result);
    }
    return result;
}
