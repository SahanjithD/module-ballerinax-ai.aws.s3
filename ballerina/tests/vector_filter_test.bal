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
import ballerina/test;

// Pure unit tests for the two halves of metadata filtering in `vector_utils.bal`:
// `translateFilters` (server-side, sent to `QueryVectors`) and `matchesFilters` (local
// evaluation, used for the filter-only `query`/`deleteByFilter` path). Every operator and
// nesting shape is tested against both, on shared fixtures, since the two must agree — a
// filter-only query must return the same set `QueryVectors` would for an equivalent filter, or
// `deleteByFilter` silently deletes the wrong entries.

const string CONTENT_KEY = "content";

isolated function filter(string key, ai:MetadataFilterOperator operator, json value) returns ai:MetadataFilter =>
    {key, operator, value};

// ---------------------------------------------------------------------------
// translateFilters — operator table, collapsing, and rejections
// ---------------------------------------------------------------------------

@test:Config {}
isolated function testTranslateFiltersEmptyListCollapsesToEmptyMap() returns ai:Error? {
    map<json> result = check translateFilters({filters: []}, CONTENT_KEY);
    test:assertEquals(result, {}, "An empty filter list must collapse to {} so 'filter' is omitted from the request");
}

@test:Config {}
isolated function testTranslateFiltersSingleFilterIsEmittedBareWithoutAndWrapper() returns ai:Error? {
    map<json> result = check translateFilters({filters: [filter("genre", ai:EQUAL, "documentary")]}, CONTENT_KEY);
    test:assertEquals(result, {"genre": "documentary"},
            "A single EQUAL filter must be a bare implicit-$eq object, not wrapped in $and");
}

@test:Config {}
isolated function testTranslateFiltersOperatorTable() returns ai:Error? {
    map<[ai:MetadataFilterOperator, string]> cases = {
        ne: [ai:NOT_EQUAL, "$ne"],
        gt: [ai:GREATER_THAN, "$gt"],
        lt: [ai:LESS_THAN, "$lt"],
        gte: [ai:GREATER_THAN_OR_EQUAL, "$gte"],
        lte: [ai:LESS_THAN_OR_EQUAL, "$lte"]
    };
    foreach [ai:MetadataFilterOperator, string] [operator, s3Operator] in cases {
        json value = operator == ai:NOT_EQUAL ? "drama" : 2020;
        map<json> result = check translateFilters({filters: [filter("year", operator, value)]}, CONTENT_KEY);
        test:assertEquals(result, {"year": {[s3Operator]: value}},
                string `Operator ${operator} must translate to '${s3Operator}'`);
    }
}

@test:Config {}
isolated function testTranslateFiltersInOperator() returns ai:Error? {
    map<json> result =
        check translateFilters({filters: [filter("genre", ai:IN, ["comedy", "documentary"])]}, CONTENT_KEY);
    test:assertEquals(result, {"genre": {"$in": ["comedy", "documentary"]}});
}

@test:Config {}
isolated function testTranslateFiltersNotInOperator() returns ai:Error? {
    map<json> result =
        check translateFilters({filters: [filter("genre", ai:NOT_IN, ["comedy", "documentary"])]}, CONTENT_KEY);
    test:assertEquals(result, {"genre": {"$nin": ["comedy", "documentary"]}});
}

@test:Config {}
isolated function testTranslateFiltersNestedAndCondition() returns ai:Error? {
    ai:MetadataFilters filters = {
        condition: ai:AND,
        filters: [filter("genre", ai:EQUAL, "drama"), filter("year", ai:GREATER_THAN_OR_EQUAL, 2020)]
    };
    map<json> result = check translateFilters(filters, CONTENT_KEY);
    test:assertEquals(result, {"$and": [{"genre": "drama"}, {"year": {"$gte": 2020}}]});
}

@test:Config {}
isolated function testTranslateFiltersNestedOrCondition() returns ai:Error? {
    ai:MetadataFilters filters = {
        condition: ai:OR,
        filters: [filter("genre", ai:EQUAL, "drama"), filter("year", ai:GREATER_THAN_OR_EQUAL, 2020)]
    };
    map<json> result = check translateFilters(filters, CONTENT_KEY);
    test:assertEquals(result, {"$or": [{"genre": "drama"}, {"year": {"$gte": 2020}}]});
}

@test:Config {}
isolated function testTranslateFiltersDeeplyNestedGroups() returns ai:Error? {
    ai:MetadataFilters innerFilters = {condition: ai:OR, filters: [filter("a", ai:EQUAL, 1), filter("b", ai:EQUAL, 2)]};
    ai:MetadataFilters outerFilters = {condition: ai:AND, filters: [innerFilters, filter("c", ai:EQUAL, 3)]};
    map<json> result = check translateFilters(outerFilters, CONTENT_KEY);
    test:assertEquals(result, {"$and": [{"$or": [{"a": 1}, {"b": 2}]}, {"c": 3}]});
}

@test:Config {}
isolated function testTranslateFiltersEncodesTimestampAsGivenNumber() returns ai:Error? {
    // The caller is responsible for passing an epoch-seconds number here, matching what
    // transformMetadata wrote — translateFilters does not attempt to re-encode a time:Utc value.
    map<json> result =
        check translateFilters({filters: [filter("createdAt", ai:GREATER_THAN_OR_EQUAL, 1755561600.0d)]},
                CONTENT_KEY);
    test:assertEquals(result, {"createdAt": {"$gte": 1755561600.0d}});
}

@test:Config {}
isolated function testTranslateFiltersRejectsFilterOnContentKey() {
    map<json>|ai:Error result = translateFilters({filters: [filter(CONTENT_KEY, ai:EQUAL, "x")]}, CONTENT_KEY);
    test:assertTrue(result is ai:Error,
            "Filtering on the (non-filterable) content key must be rejected client-side, not sent to AWS");
}

@test:Config {}
isolated function testTranslateFiltersRejectsNullEquality() {
    map<json>|ai:Error result = translateFilters({filters: [filter("genre", ai:EQUAL, ())]}, CONTENT_KEY);
    test:assertTrue(result is ai:Error, "S3 Vectors does not support filtering for a null value");
}

@test:Config {}
isolated function testTranslateFiltersRejectsEmptyInArray() {
    map<json>|ai:Error result = translateFilters({filters: [filter("genre", ai:IN, [])]}, CONTENT_KEY);
    test:assertTrue(result is ai:Error, "$in requires a non-empty array");
}

@test:Config {}
isolated function testTranslateFiltersRejectsNonArrayForIn() {
    map<json>|ai:Error result = translateFilters({filters: [filter("genre", ai:IN, "comedy")]}, CONTENT_KEY);
    test:assertTrue(result is ai:Error, "$in requires an array value, not a bare scalar");
}

@test:Config {}
isolated function testTranslateFiltersRejectsStringForRangeOperator() {
    // AWS's own metadata-filtering documentation states $gt/$gte/$lt/$lte accept Number only.
    map<json>|ai:Error result =
        translateFilters({filters: [filter("createdAt", ai:GREATER_THAN, "2026-08-19")]}, CONTENT_KEY);
    test:assertTrue(result is ai:Error,
            "A string value for a range operator must be rejected client-side, since S3 Vectors range " +
            "operators only accept numbers");
}

// ---------------------------------------------------------------------------
// matchesFilters — local evaluation, mirroring ballerina/ai's own entryMatchesFilters semantics
// ---------------------------------------------------------------------------

@test:Config {}
isolated function testMatchesFiltersEmptyListMatchesEverything() returns ai:Error? {
    // AND over zero conditions is vacuously true, matching ballerina/ai's evaluateCondition.
    test:assertTrue(check matchesFilters({genre: "drama"}, {filters: []}));
}

@test:Config {}
isolated function testMatchesFiltersEqualOperator() returns ai:Error? {
    map<json> metadata = {genre: "documentary"};
    test:assertTrue(check matchesFilters(metadata, {filters: [filter("genre", ai:EQUAL, "documentary")]}));
    test:assertFalse(check matchesFilters(metadata, {filters: [filter("genre", ai:EQUAL, "drama")]}));
}

@test:Config {}
isolated function testMatchesFiltersMissingKeyIsNonMatch() returns ai:Error? {
    test:assertFalse(check matchesFilters({}, {filters: [filter("genre", ai:EQUAL, "documentary")]}),
            "A metadata map missing the filtered key must not match");
}

@test:Config {}
isolated function testMatchesFiltersNotEqualOperator() returns ai:Error? {
    test:assertTrue(check matchesFilters({genre: "drama"}, {filters: [filter("genre", ai:NOT_EQUAL, "comedy")]}));
    test:assertFalse(check matchesFilters({genre: "drama"}, {filters: [filter("genre", ai:NOT_EQUAL, "drama")]}));
}

@test:Config {}
isolated function testMatchesFiltersInOperator() returns ai:Error? {
    ai:MetadataFilter cond = filter("genre", ai:IN, ["comedy", "documentary"]);
    test:assertTrue(check matchesFilters({genre: "comedy"}, {filters: [cond]}));
    test:assertFalse(check matchesFilters({genre: "horror"}, {filters: [cond]}));
}

@test:Config {}
isolated function testMatchesFiltersNotInOperator() returns ai:Error? {
    ai:MetadataFilter cond = filter("genre", ai:NOT_IN, ["comedy", "documentary"]);
    test:assertFalse(check matchesFilters({genre: "comedy"}, {filters: [cond]}));
    test:assertTrue(check matchesFilters({genre: "horror"}, {filters: [cond]}));
}

@test:Config {}
isolated function testMatchesFiltersRangeOperators() returns ai:Error? {
    map<json> metadata = {year: 2021};
    test:assertTrue(check matchesFilters(metadata, {filters: [filter("year", ai:GREATER_THAN, 2020)]}));
    test:assertFalse(check matchesFilters(metadata, {filters: [filter("year", ai:GREATER_THAN, 2021)]}));
    test:assertTrue(check matchesFilters(metadata, {filters: [filter("year", ai:GREATER_THAN_OR_EQUAL, 2021)]}));
    test:assertTrue(check matchesFilters(metadata, {filters: [filter("year", ai:LESS_THAN, 2022)]}));
    test:assertTrue(check matchesFilters(metadata, {filters: [filter("year", ai:LESS_THAN_OR_EQUAL, 2021)]}));
}

@test:Config {}
isolated function testMatchesFiltersAndRequiresAllTrue() returns ai:Error? {
    ai:MetadataFilters filters = {
        condition: ai:AND,
        filters: [filter("genre", ai:EQUAL, "drama"), filter("year", ai:GREATER_THAN_OR_EQUAL, 2020)]
    };
    test:assertTrue(check matchesFilters({genre: "drama", year: 2021}, filters));
    test:assertFalse(check matchesFilters({genre: "drama", year: 2019}, filters));
}

@test:Config {}
isolated function testMatchesFiltersOrRequiresAtLeastOneTrue() returns ai:Error? {
    ai:MetadataFilters filters = {
        condition: ai:OR,
        filters: [filter("genre", ai:EQUAL, "drama"), filter("year", ai:GREATER_THAN_OR_EQUAL, 2020)]
    };
    test:assertTrue(check matchesFilters({genre: "comedy", year: 2021}, filters));
    test:assertFalse(check matchesFilters({genre: "comedy", year: 2019}, filters));
}

@test:Config {}
isolated function testMatchesFiltersDeeplyNestedGroups() returns ai:Error? {
    ai:MetadataFilters innerFilters = {condition: ai:OR, filters: [filter("a", ai:EQUAL, 1), filter("b", ai:EQUAL, 2)]};
    ai:MetadataFilters outerFilters = {condition: ai:AND, filters: [innerFilters, filter("c", ai:EQUAL, 3)]};
    test:assertTrue(check matchesFilters({a: 0, b: 2, c: 3}, outerFilters));
    test:assertFalse(check matchesFilters({a: 0, b: 0, c: 3}, outerFilters));
}

@test:Config {}
isolated function testMatchesFiltersRejectsNonNumericRangeComparison() {
    boolean|ai:Error result = matchesFilters({year: "not-a-number"}, {filters: [filter("year", ai:GREATER_THAN, 2020)]});
    test:assertTrue(result is ai:Error,
            "A non-numeric stored value compared with a range operator must surface as an error, mirroring " +
            "ballerina/ai's own compareValues behaviour rather than silently evaluating to false");
}

@test:Config {}
isolated function testMatchesFiltersRejectsNonArrayInValue() {
    // translateSingleFilter rejects a non-array $in/$nin value client-side (see
    // testTranslateFiltersRejectsNonArrayForIn); local evaluation must reject the same malformed
    // input too, rather than silently treating it as "matches nothing" — otherwise a
    // filter-only query or deleteByFilter would quietly no-op on a caller mistake that the
    // equivalent QueryVectors path would reject loudly.
    boolean|ai:Error result = matchesFilters({genre: "comedy"}, {filters: [filter("genre", ai:IN, "comedy")]});
    test:assertTrue(result is ai:Error, "A non-array IN filter value must be rejected, not silently non-matched");
}

@test:Config {}
isolated function testMatchesFiltersRejectsEmptyInArray() {
    boolean|ai:Error result = matchesFilters({genre: "comedy"}, {filters: [filter("genre", ai:IN, [])]});
    test:assertTrue(result is ai:Error, "An empty IN array must be rejected, matching translateSingleFilter");
}

// ---------------------------------------------------------------------------
// Agreement between translateFilters and matchesFilters on the same fixtures — this is the
// property that keeps a server-side-filtered QueryVectors and a local-filtered ListVectors scan
// returning the same results for the same filter.
// ---------------------------------------------------------------------------

type AgreementCase record {|
    string description;
    ai:MetadataFilters filters;
    map<json> metadata;
    boolean expectedMatch;
|};

@test:Config {}
isolated function testTranslationAndEvaluationAgree() returns ai:Error? {
    AgreementCase[] cases = [
        {
            description: "simple equality match",
            filters: {filters: [filter("genre", ai:EQUAL, "drama")]},
            metadata: {genre: "drama"},
            expectedMatch: true
        },
        {
            description: "simple equality non-match",
            filters: {filters: [filter("genre", ai:EQUAL, "drama")]},
            metadata: {genre: "comedy"},
            expectedMatch: false
        },
        {
            description: "AND of equality and range, both satisfied",
            filters: {
                condition: ai:AND,
                filters: [filter("genre", ai:EQUAL, "drama"), filter("year", ai:GREATER_THAN_OR_EQUAL, 2020)]
            },
            metadata: {genre: "drama", year: 2021},
            expectedMatch: true
        },
        {
            description: "AND of equality and range, one unsatisfied",
            filters: {
                condition: ai:AND,
                filters: [filter("genre", ai:EQUAL, "drama"), filter("year", ai:GREATER_THAN_OR_EQUAL, 2020)]
            },
            metadata: {genre: "drama", year: 2019},
            expectedMatch: false
        },
        {
            description: "OR of two conditions, one satisfied",
            filters: {
                condition: ai:OR,
                filters: [filter("genre", ai:EQUAL, "drama"), filter("year", ai:GREATER_THAN_OR_EQUAL, 2020)]
            },
            metadata: {genre: "comedy", year: 2021},
            expectedMatch: true
        },
        {
            description: "IN membership",
            filters: {filters: [filter("genre", ai:IN, ["comedy", "documentary"])]},
            metadata: {genre: "documentary"},
            expectedMatch: true
        },
        {
            description: "NOT_IN exclusion",
            filters: {filters: [filter("genre", ai:NOT_IN, ["comedy", "documentary"])]},
            metadata: {genre: "documentary"},
            expectedMatch: false
        }
    ];

    foreach AgreementCase testCase in cases {
        // The server-side path: translate the filter (proving it doesn't error) — the actual
        // agreement being tested is between what QueryVectors WOULD return for this metadata
        // against the translated filter, and what the local evaluator decides for the same pair.
        // Since there is no live index to query against, the local evaluator is asserted to
        // agree with the documented S3 Vectors filter semantics directly, and `translateFilters`
        // is asserted to succeed producing a well-formed filter for the same input.
        map<json> _ = check translateFilters(testCase.filters, CONTENT_KEY);
        boolean localResult = check matchesFilters(testCase.metadata, testCase.filters);
        test:assertEquals(localResult, testCase.expectedMatch,
                string `Case '${testCase.description}': local evaluation disagreed with the expected S3 ` +
                "Vectors filter semantics");
    }
}
