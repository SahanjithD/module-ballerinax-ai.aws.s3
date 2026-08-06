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

# A single S3 bucket together with the paths to load from it. Several sources may be
# configured per loader; their documents are aggregated in the order given. S3 has no real
# folders, so a path is interpreted against key prefixes (see the README's "How paths are
# resolved").
public type Source record {|

    # The name of the S3 bucket. It must live in the region set on `s3:ConnectionConfig`, which
    # is shared by every source — a bucket in a different region fails with an opaque AWS
    # redirect error, so use one loader per region
    string bucket;
    
    # One or more object keys or key prefixes to load, read in the order given. A value ending
    # in `/` is treated as a prefix; any other value is tried first as an exact key and, on a
    # miss, as a prefix. Paths are not de-duplicated: if two paths both match an object (say
    # `reports/` and `reports/q1.pdf`), it is loaded once per matching path, which would index
    # the same text twice. Keep paths disjoint.
    # Optional: omit it to load the whole bucket (non-recursively unless `recursive` is set),
    # which lists with the S3 prefix left off. An empty-string element is also accepted and means
    # the same whole-bucket listing.
    string[] paths?;

    # Whether a prefix is traversed into nested "sub-folders". Applies to every prefix in `paths`.
    # When `false` (the default) only keys directly under a prefix are loaded — keys whose
    # remainder after the prefix contains a further `/` are skipped
    boolean recursive = false;

    # Case-insensitive extension allowlist applied to keys found while walking a prefix, for every
    # prefix in `paths` (a leading dot is optional, e.g. `pdf` and `.PDF` both match `report.pdf`).
    # An explicitly named exact key is always loaded regardless of this list.
    #
    # Filtering happens *after* listing, so this reduces how many documents are returned but
    # not how many keys are listed: a prefix holding 5000 images and 40 PDFs still exceeds the
    # one-page listing limit even when filtered to `["pdf"]`. Narrow the path for that.
    # An empty array behaves like `()` — everything is allowed.
    # Defaults to `()`, meaning all supported types
    string[]? includeExtensions = ();
|};

# Loader-wide options bounding what a single load reads.
public type LoaderOptions record {|
    # The maximum size, in bytes, of a single object read into memory. An object larger
    # than this fails with a clear `ai:Error` rather than risking an out-of-memory
    # condition (objects are extracted entirely in memory, never written to disk).
    # Extraction transiently needs roughly twice this, since the bytes are copied across
    # the Java boundary, plus room for the extracted text. Defaults to 100 MiB
    int maxObjectSize = 104857600;
|};
