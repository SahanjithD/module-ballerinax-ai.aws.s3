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

# A bucket and the paths to load from it.
public type Source record {|
    # Name of the S3 bucket to read from
    string bucket;

    # Object keys or key prefixes to load. A value ending in `/` is a prefix; any other value is
    # tried as a key first, then as a prefix. Omit to load the whole bucket
    string[] paths?;

    # Whether to also load objects in nested folders under each prefix
    boolean recursive = false;

    # File extensions to load while walking a prefix, e.g. `["pdf", "docx"]`. Empty or unset loads
    # every supported type. Keys named directly in `paths` are always loaded
    string[]? includeExtensions = ();
|};

# Options that apply to the whole loader.
public type LoaderOptions record {|
    # Largest object, in bytes, that is read into memory. Defaults to 100 MiB
    int maxObjectSize = 104857600;
|};
