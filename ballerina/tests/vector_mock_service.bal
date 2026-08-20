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

import ballerina/http;

// An in-process stand-in for the S3 Vectors service. There is no S3 Vectors emulator (unlike,
// say, LocalStack for plain S3 — S3 Vectors support there is tracked but backlogged), so
// `vector_store_test.bal` points a real `VectorStore` at this listener instead of a live
// endpoint. It does not verify SigV4 signatures — that would just be re-testing
// `ballerinax/aws.auth`, which is exercised separately by the header-shape tests in
// `vector_mapping_test.bal` (`testSignedHeadersIncludeTheExpectedSigV4Set` and
// `testSignedHeadersIncludeSessionTokenForTemporaryCredentials`) — it only
// records what each operation sent and returns whatever response the test queued for it,
// letting the store's own request-building, batching, pagination, and response/error mapping
// run for real against something.

const int MOCK_PORT = 20990;

// One canned response for one call to an operation.
type MockResponse record {|
    int statusCode = 200;
    json body = {};
    map<string> headers = {};
|};

isolated class MockS3VectorsControl {
    private map<MockResponse[]> queuedResponses = {};
    private map<json[]> capturedRequests = {};

    // Queues a response to be returned the next time `operation` is called. Multiple calls queue
    // multiple responses in order (FIFO) — used to script a paginated sequence.
    isolated function queueResponse(string operation, MockResponse response) {
        lock {
            MockResponse[] queue = self.queuedResponses[operation] ?: [];
            queue.push(response.clone());
            self.queuedResponses[operation] = queue;
        }
    }

    // Pops and returns the next queued response for `operation`, or a default empty 200 `{}`
    // when nothing was queued — matching what `PutVectors`/`DeleteVectors` actually return.
    isolated function nextResponse(string operation) returns MockResponse {
        lock {
            MockResponse[]? queue = self.queuedResponses[operation];
            if queue is MockResponse[] && queue.length() > 0 {
                return queue.shift().clone();
            }
        }
        return {statusCode: 200, body: {}};
    }

    isolated function recordRequest(string operation, json body) {
        lock {
            json[] requests = self.capturedRequests[operation] ?: [];
            requests.push(body.clone());
            self.capturedRequests[operation] = requests;
        }
    }

    // Every request body captured for `operation`, in call order.
    isolated function requestsFor(string operation) returns json[] {
        lock {
            return (self.capturedRequests[operation] ?: []).clone();
        }
    }

    isolated function callCount(string operation) returns int {
        lock {
            return (self.capturedRequests[operation] ?: []).length();
        }
    }

    // Clears all queued responses and captured requests between tests.
    isolated function reset() {
        lock {
            self.queuedResponses = {};
            self.capturedRequests = {};
        }
    }
}

final MockS3VectorsControl mockS3VectorsControl = new;

service / on new http:Listener(MOCK_PORT) {
    // S3 Vectors calls are all `POST /{OperationName}` — a single path segment names the
    // operation, matching what `s3_vectors_api.bal`'s `invoke` sends.
    resource function post [string operation](http:Request req) returns http:Response|error {
        json requestBody = check req.getJsonPayload();
        mockS3VectorsControl.recordRequest(operation, requestBody);

        MockResponse mockResponse = mockS3VectorsControl.nextResponse(operation);
        http:Response response = new;
        response.statusCode = mockResponse.statusCode;
        response.setJsonPayload(mockResponse.body);
        foreach [string, string] [headerName, headerValue] in mockResponse.headers.entries() {
            response.setHeader(headerName, headerValue);
        }
        return response;
    }
}
