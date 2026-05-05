# Decisions Log

Chronological log of design decisions made during implementation. All agents should read this file at session start and append to it when making decisions that affect other modules.

---

## 2026-05-03 — Use a single shared DECISIONS.md for cross-agent communication
**Context:** Agents working in parallel need a way to communicate decisions without real-time coordination.
**Decision:** A single chronological `DECISIONS.md` in the repo root. Agents read it before starting work and append when they make decisions that affect other modules.
**Affects:** All agents / workflow.

## 2026-05-04 — Codegen scaffolding: DirectedCodegen with Smithy 1.69.0, Java 17
**Context:** Setting up the smithy-lua code generator following the Smithy codegen guide.
**Decision:** Use the `DirectedCodegen` / `CodegenDirector` pattern from `smithy-codegen-core`. Plugin name is `lua-client-codegen`. Smithy version pinned to 1.69.0. Java 17 target. Gradle 8.13 wrapper. Multi-module layout under `codegen/` with `smithy-lua-codegen` (plugin JAR) and `smithy-lua-codegen-test` (integration test project).
**Key classes:** `LuaCodegenPlugin`, `DirectedLuaCodegen`, `LuaContext`, `LuaSettings`, `LuaWriter`, `LuaSymbolProvider`, `LuaIntegration`, `LuaImportContainer`.
**Affects:** All codegen work, aws-sdk-lua codegen (will extend this).

## 2026-05-04 — invokeOperation signature
**Context:** Need to define how operation metadata and per-call overrides flow into the pipeline.
**Decision:** `client:invokeOperation(input, operation, options) -> output, err`. Three params: user input table, static codegen operation table, optional overrides.
**Affects:** client.lua, all generated operation code.

## 2026-05-04 — Per-operation overrides are plugins-only
**Context:** Need a mechanism for per-call config changes (add/remove interceptors, change region, etc.).
**Decision:** `options = { plugins = { fn, fn, ... } }`. Each plugin receives a mutable shallow copy of the client config. No shorthand fields for now — sugar deferred to post-hackathon.
**Affects:** client.lua, generated operation methods.

## 2026-05-04 — Minimal first-call config, stub the rest
**Context:** Don't want to over-design upfront. Need to ship a working call fast.
**Decision:** Lock down: protocol, http_client, endpoint_provider, identity_resolver, signer, signing_name, region, service_id. Stub: retry_strategy, auth_schemes, auth_scheme_resolver, interceptors. Full contract in INVOKE_OPERATION.md.
**Affects:** All runtime modules, codegen.

## 2026-05-04 — Codegen file layout: flat per-service directory with client.lua + types.lua
**Context:** Need to decide how generated Lua files are organized per service.
**Decision:** Each service gets a flat directory named after the service (lowercased). Two `.lua` files: `client.lua` (constructor + operation methods) and `types.lua` (all schemas — structures, unions, enums, errors). Two `.d.tl` files alongside. Example: `weather/client.lua`, `weather/types.lua`, `weather/client.d.tl`, `weather/types.d.tl`.
**Affects:** All codegen, aws-sdk-lua codegen, require() paths in runtime.

## 2026-05-04 — Schema format for generated types
**Context:** Schema-serde approach requires codegen to emit runtime-readable schema declarations.
**Decision:** Each schema is a Lua table with `type` (string/number/boolean/structure/union/list/map/etc.), `members` (table of member schemas), and per-member `traits` (required, http_label, http_query, http_header, http_payload, json_name, xml_name, timestamp_format, etc.). Lists include `member_type`, maps include `key_type`/`value_type`. Error shapes include `error` field with the error kind.
**Affects:** Runtime serde/protocol implementations (must understand this schema format).

## 2026-05-04 — LuaSymbolProvider uses ShapeVisitor pattern
**Context:** Need proper symbol resolution for different shape types.
**Decision:** `LuaSymbolProvider` implements both `SymbolProvider` and `ShapeVisitor<Symbol>`. Service/operation shapes → `client.lua`, aggregate shapes (structure/union/enum) → `types.lua`, simple shapes → native Lua type names with no definition file.
**Affects:** All codegen, WriterDelegator file routing.

## 2026-05-04 — Schema-serde design for Lua: no ShapeSerializer/ShapeDeserializer interfaces
**Context:** The schema-serde SEP defines ShapeSerializer/ShapeDeserializer interfaces for typed languages. In Lua, shapes are plain tables — codecs can walk them directly using schemas.
**Decision:** Collapse the ShapeSerializer/ShapeDeserializer abstraction into the Codec. A codec provides `serialize(self, value, schema) -> string, err` and `deserialize(self, bytes, schema) -> value, err`. The codec walks the schema internally. Protocols use codecs for body serde and handle HTTP bindings separately.
**Rationale:** SEP explicitly allows dynamic languages to use a single `write(schema, value)` / `read(schema)` approach. Lua tables are transparent — no opaque types requiring visitor patterns.
**Affects:** All codec implementations, protocol implementations, codegen (schemas only, no per-shape serde code).

## 2026-05-04 — Schema representation as plain Lua tables
**Context:** Need a runtime schema type for serde.
**Decision:** Schemas are plain Lua tables: `{ id, type, members (structure/union), member (list), key/value (map), traits }`. Member schemas combine member + target per SEP guidance: `{ name, target, traits }`. Traits are a sub-table keyed by string constants from `schema.trait`. Shape types are string constants from `schema.type`.
**Affects:** Codegen (must emit schemas in this format), all codec/protocol implementations.

## 2026-05-04 — JSON codec settings for protocol differentiation
**Context:** Different protocols use the JSON codec differently (awsJson ignores jsonName, restJson uses it; different default timestamp formats).
**Decision:** JSON codec accepts settings: `{ use_json_name = bool, default_timestamp_format = string }`. Protocol constructs codec with appropriate settings at client build time.
**Affects:** Protocol implementations (json.lua, restjson.lua).

## 2026-05-04 — Pure Lua JSON encoder/decoder (no external dependency)
**Context:** Constitution says JSON can use cjson or dkjson, but we need schema-aware serde anyway.
**Decision:** Write our own pure Lua JSON encoder and decoder. The codec layer uses them internally. This avoids an external dependency and gives us full control over Smithy-specific formatting (NaN/Infinity as strings, integer vs float distinction, base64 blobs).
**Affects:** No external JSON dependency needed.

## 2026-05-04 — Error module: three categories, retry classification helpers
**Context:** Need structured error types for the retry strategy to classify errors.
**Decision:** `error.lua` defines three categories (`api`, `http`, `sdk`) with constructors. Classification helpers: `is_throttle` (429 + AWS throttle error codes), `is_transient` (HTTP errors + 500/502/503/504), `is_timeout` (RequestTimeout/RequestTimeoutException), `is_retryable` (any of the above). Throttle codes match Go SDK v2's `DefaultThrottleErrorCodes`.
**Affects:** All protocol implementations (must use `error.new_api_error` for service errors), retry strategy.

## 2026-05-04 — Retry strategy: optional, nil = single attempt
**Context:** Need to wire retry into client.lua without breaking existing code that doesn't set retry_strategy.
**Decision:** `config.retry_strategy` is optional. If nil, client.lua does a single attempt (no retry loop). If set, the full acquire_token/retry_token/record_success loop runs. This preserves backward compatibility.
**Affects:** client.lua, all generated client constructors (can optionally wire standard retry).

## 2026-05-04 — Standard retry constants match Go SDK v2
**Context:** Need concrete values for token bucket and backoff.
**Decision:** Token bucket: 500 capacity, 5 retry cost, 10 timeout cost, 1 success increment. Backoff: `rand() * 2^attempt`, capped at 20s. Max 3 attempts. All configurable via options table. Constants match `aws-sdk-go-v2/aws/retry/standard.go`.
**Affects:** Default retry behavior for all SDK clients.

## 2026-05-04 — Request URL rebuild on retry via _path stash
**Context:** Endpoint resolution appends the endpoint URL to the request path. On retry, we need to re-resolve the endpoint and rebuild the URL, but the original path is lost after the first attempt.
**Decision:** After serialization, stash `request._path = request.url` (the protocol-produced path). On each attempt, rebuild: `request.url = endpoint.url .. request._path`. This is an internal implementation detail, not part of the public contract.
**Affects:** client.lua internals only.

## 2026-05-04 — Schema members are table-keyed, not array
**Context:** Codegen (session 2) emitted `members = { Name = { type = "string" } }` (table-keyed). Codec (session 3) expected `members = { { name = "Name", target = { type = "string" } } }` (array). Parallel agents didn't coordinate on the format.
**Decision:** Adopt the codegen format. `Schema.members` is `{string: Schema}` — a table keyed by member name where each value is itself a Schema. No separate `MemberSchema` type, no `name`/`target` wrapper. Traits live directly on the member schema.
**Rationale:** Table-keyed is more natural in Lua (direct field access, no linear scan). Matches how users think about structures.
**Changed:** schema.lua, schema.d.tl, codec/json.lua, test_codec_json.lua. All 150 tests pass.
**Affects:** All codec/protocol implementations, codegen (already correct), any code using `schema.member()`.

## 2026-05-04 — awsJson1.0/1.1 protocol implementation
**Context:** Need a ClientProtocol for awsJson services (SQS, DynamoDB, etc.).
**Decision:** `protocol/json.lua` implements `serialize` and `deserialize`. Serialize sets `Content-Type: application/x-amz-json-{version}`, `X-Amz-Target: {service_id}.{operation_name}`, JSON body via codec. Deserialize checks status code, parses errors from `x-amzn-errortype` header or `__type` body field, decodes success via codec. awsJson does NOT use `json_name` — member names go on the wire as-is.
**Affects:** Generated clients using awsJson protocol, client.lua pipeline.

## 2026-05-04 — LuaIntegration.writeAdditionalFiles hook for codegen extensibility
**Context:** aws-sdk-lua needs to extend smithy-lua codegen to emit additional generated files (e.g. SDK-specific client wiring, credential chain setup). Need a simple, open-ended extension point.
**Decision:** Added `writeAdditionalFiles(LuaContext)` default method to `LuaIntegration`. Called in `DirectedLuaCodegen.customizeAfterIntegrations` — runs after all standard codegen (shapes, services, Teal) is complete. Integration authors override it to generate whatever they need using the full context (writer delegator, model, service, symbol provider).
**Affects:** aws-sdk-lua codegen (will implement this hook), any future codegen extensions.

## 2026-05-04 — client.lua uses colon-call for protocol methods
**Context:** client.lua was calling `config.protocol.serialize(input, operation)` (dot-call), but real protocol implementations (e.g. `protocol/json.lua`) define methods with `self` and expect colon-call. This worked in tests because mocks used plain functions without `self`, but broke when wiring the generated SQS client to the real awsJson protocol.
**Decision:** client.lua now uses `config.protocol:serialize(input, operation)` and `config.protocol:deserialize(response, operation)`. All protocol mock tables in tests must accept `self` as the first parameter.
**Affects:** client.lua, all test mocks that provide a protocol table, any future protocol implementations.

## 2026-05-04 — HTTP client: pluggable with runtime resolution
**Context:** Need a real HTTP client for convergence. No luasocket available, but libcurl loads via LuaJIT FFI and curl CLI is available.
**Decision:** HTTP client is resolved at client construction time via `http/client.lua:resolve()`. Resolution order: libcurl FFI → curl subprocess. Each backend is a separate module (`http/curl_ffi.lua`, `http/curl_subprocess.lua`) with `available()` and `new()`. User can bypass resolution by passing `config.http_client` explicitly.
**Rationale:** Multiple backends needed for portability. FFI is preferred (no subprocess overhead, proper streaming). Subprocess is universal fallback. luasocket slot reserved for future.
**Affects:** Client construction, any code that needs a default HTTP client.

## 2026-05-04 — STS uses awsQuery, not awsJson
**Context:** Attempted convergence with STS GetCallerIdentity assuming awsJson 1.1. STS returned 302 redirect.
**Decision:** STS is an awsQuery service. Pivoted convergence to DynamoDB ListTables (awsJson 1.0). Kept hand-written STS client files for future awsQuery protocol work.
**Affects:** Phase 4 protocol breadth — awsQuery implementation needed for STS, IAM, etc.

## 2026-05-04 — Credential provider lives in runtime/credentials/ (smithy-lua for now)
**Context:** Constitution places credential providers in aws-sdk-lua, but for convergence we need at least the environment provider.
**Decision:** Environment credential provider at `runtime/credentials/environment.lua` in smithy-lua for now. Will migrate to aws-sdk-lua when that repo has runtime code. The provider returns a function conforming to the identity_resolver interface.
**Affects:** Future aws-sdk-lua credential chain work.

## 2026-05-04 — Endpoint resolution is a first-class pipeline step with builtIn + context param binding
**Context:** Need to wire codegen-emitted endpoint rulesets into the runtime pipeline. The runtime endpoint.lua evaluator already exists (session 6), but nothing generates rulesets or binds parameters.
**Decision:** Three-part design:
1. **Runtime (client.lua):** `do_attempt` binds endpoint parameters before calling `endpoint_provider(params)`. BuiltIn params are bound from config fields: `Region` ← `config.region`, `UseFIPS` ← `config.use_fips`, `UseDualStack` ← `config.use_dual_stack`, `Endpoint` ← `config.endpoint_url`. Per-operation context params are bound from `operation.context_params` (a table mapping ruleset param name → input field name).
2. **Codegen (EndpointRulesetGenerator.java):** Reads the `endpointRuleSet` trait from the service shape, walks the Node tree, and emits it as a Lua table literal in `endpoint_rules.lua`.
3. **Codegen (DirectedLuaCodegen.java):** Generated client constructor sets a default `endpoint_provider` (closure over `endpoint_rules` + `endpoint.resolve`) if the user doesn't provide one. Operations emit `context_params` from `@contextParam` traits on input members.
**Key property:** `endpoint_provider` remains user-configurable — the generated default is just the fallback.
**Affects:** client.lua, all generated service clients, codegen plugin.

## 2026-05-04 — Endpoint parameter names use Smithy ruleset casing (PascalCase)
**Context:** The endpoint ruleset defines parameters like `Region`, `UseFIPS`, `UseDualStack`, `Endpoint` (PascalCase). The runtime config uses `region`, `use_fips`, etc. (snake_case).
**Decision:** The builtIn binding in client.lua maps snake_case config fields to PascalCase ruleset parameter names. The `endpoint_provider` function always receives PascalCase params matching the ruleset definitions. Mock endpoint providers in tests must use `params.Region` not `params.region`.
**Affects:** All code that provides or consumes endpoint_provider functions.

## 2026-05-04 — ClientProtocol interface extracted to runtime/protocol module
**Context:** The protocol interface (serialize/deserialize) was duck-typed — only defined implicitly by how client.lua called it. The Teal type was inline in client.d.tl with incorrect signatures (missing self).
**Decision:** Created `runtime/protocol.lua` (documentation-only) and `runtime/protocol.d.tl` as the canonical definition. `protocol.d.tl` exports `ClientProtocol` (with correct `self` signatures for colon-call) and `Operation` records. `client.d.tl` imports from `protocol` instead of defining them inline. Protocol implementations (e.g. `awsjson.d.tl`) import `Operation` from `protocol` instead of `client`.
**Affects:** All protocol implementations (.d.tl files), client.d.tl, any future code that types the protocol interface.

## 2026-05-04 — Renamed protocol/json to protocol/awsjson
**Context:** `protocol/json.lua` was ambiguous — it could be confused with the JSON codec or a generic JSON protocol.
**Decision:** Renamed to `protocol/awsjson.lua` (and `.d.tl`). Future protocols will follow the same naming: `protocol/restjson.lua`, `protocol/query.lua`, etc.
**Affects:** All code that requires the awsJson protocol module.

## 2026-05-04 — restJson1 protocol implementation with full HTTP bindings
**Context:** Need a ClientProtocol for restJson1 services (Lambda, API Gateway, etc.) which use HTTP bindings unlike awsJson.
**Decision:** `protocol/restjson.lua` implements serialize/deserialize with full HTTP binding support. Serialization partitions input members by schema traits: `http_label` → URI path expansion, `http_query`/`http_query_params` → query string, `http_header`/`http_prefix_headers` → headers, `http_payload` → body (structure/blob/string), unbound → JSON body via codec. Deserialization is the mirror: `http_response_code` → status code, headers → member values, `http_payload` → body, unbound → JSON decode. The JSON codec is configured with `use_json_name = true` (unlike awsJson). When `@httpPayload` targets a structure, that structure's schema is the root for codec serde — not wrapped in the outer input. When no body members have values, no Content-Type header is set and body is empty.
**Affects:** Generated clients using restJson1 protocol, codegen (already emits all HTTP traits on schemas).

## 2026-05-04 — Protocol test generation: auto-discovery + direct protocol testing
**Context:** Need to generate Lua test files from Smithy `@httpRequestTests` / `@httpResponseTests` traits to validate protocol implementations.
**Decision:** Three-part design:
1. **HttpProtocolTestGenerator** — a `LuaIntegration` in `smithy-lua-codegen` that iterates operations, extracts test cases from traits, filters by protocol and `appliesTo`, and emits Lua test files. Request tests call `protocol:serialize()` directly and assert HTTP request fields. Response/error tests call `protocol:deserialize()` with mock HTTP responses and assert output/error fields. Body comparison uses semantic JSON comparison via `json_decoder.decode()` + `deep_eq()`.
2. **protocoltest/ Gradle project** — uses `Model.assembler().discoverModels()` in a `generate-smithy-build` task to auto-discover all service shapes from `smithy-protocol-tests` and `smithy-aws-protocol-tests` JARs. Generates `smithy-build.json` programmatically with one projection per service. No manual maintenance needed — new protocol test services are picked up automatically.
3. **Generated test files** — one file per operation per test type: `test_{op}_request.lua`, `test_{op}_response.lua`, `test_{op}_{error}_error.lua`. Each file is self-contained with test helpers (assert_eq, assert_header, assert_json_eq, deep_eq, etc.).
**Key details:** Lua long strings `[[...]]` used for body literals (avoids escaping issues). Protocol `service_id` passed at construction for `X-Amz-Target` header. Test helpers written manually (not via `block()`) to avoid if/else/end issues.
**Affects:** All protocol implementations (tests validate them), codegen (HttpProtocolTestGenerator is SPI-registered).

## 2026-05-04 — Protocol tests call serialize/deserialize directly, not through invokeOperation
**Context:** Go SDK protocol tests go through the full client pipeline with middleware capture. For Lua, the pipeline is simpler.
**Decision:** Protocol tests call `protocol:serialize(input, operation)` and `protocol:deserialize(response, operation)` directly, bypassing the client pipeline. This tests the protocol implementation in isolation, which is the primary goal. Full pipeline integration is tested separately via harness tests.
**Rationale:** Simpler generated code, no need to mock the full client stack, and directly validates the protocol contract.
**Affects:** Protocol test files only — they don't exercise retry, signing, or endpoint resolution.

## 2026-05-04 — XML codec: pure Lua XML serializer/deserializer with schema-aware serde
**Context:** Need XML codec for restXml and awsQuery response deserialization.
**Decision:** `codec/xml.lua` implements serialize/deserialize with full support for `@xmlAttribute`, `@xmlFlattened`, `@xmlName`, `@xmlNamespace`. Includes a minimal XML parser (tag/attrs/children/text tree). Exposes `parse_xml`, `decode_node`, `xml_escape`, `xml_unescape` for protocol-level use. Default timestamp format is `date-time` (ISO 8601). Reuses base64 from JSON codec.
**Affects:** restXml protocol, awsQuery/ec2Query response deserialization.

## 2026-05-04 — awsQuery/ec2Query: shared serializer with ec2 mode flag
**Context:** awsQuery and ec2Query share most serialization logic but differ in list flattening, key capitalization, and error/response wrapping.
**Decision:** `protocol/awsquery.lua` accepts `settings.ec2 = true` to enable ec2 mode. ec2 mode: always-flattened lists, capitalize first letter of all key segments, `ec2QueryName` trait takes precedence over `xmlName`, no `Result` wrapper in response, different error XML format (`<Response><Errors><Error>` vs `<ErrorResponse><Error>`). `protocol/ec2query.lua` is a thin wrapper that sets `ec2 = true`.
**Affects:** Generated clients using awsQuery or ec2Query protocols, codegen (must emit `ec2_query_name` trait).

## 2026-05-04 — Added ec2_query_name and aws_query_error traits to schema
**Context:** ec2Query needs `ec2QueryName` trait for query key resolution, awsQuery needs `awsQueryError` for custom error codes.
**Decision:** Added `EC2_QUERY_NAME = "ec2_query_name"` and `AWS_QUERY_ERROR = "aws_query_error"` to `schema.trait` constants in both `schema.lua` and `schema.d.tl`.
**Affects:** Codegen (must emit these traits on schemas), awsQuery/ec2Query protocol implementations.

## 2026-05-04 — CBOR codec: pure Lua CBOR encoder/decoder using LuaJIT FFI
**Context:** Need CBOR codec for Smithy RPCv2 CBOR protocol.
**Decision:** `codec/cbor.lua` implements RFC 8949 subset needed for Smithy. Uses LuaJIT `bit` library for bitwise ops and `ffi` for float encoding/decoding (cast between float/double and byte arrays). Supports all CBOR major types, half/single/double precision floats, tags (tag 1 for timestamps). Integers encoded in smallest possible representation. Floats use float32 when no precision loss, float64 otherwise. Half-precision only for special values (NaN, ±Infinity). Exposes `decode_item` for raw CBOR decoding.
**Affects:** rpcv2Cbor protocol.

## 2026-05-04 — rpcv2Cbor protocol: POST to /service/{svc}/operation/{op}
**Context:** Need Smithy RPCv2 CBOR protocol for modern AWS services.
**Decision:** `protocol/rpcv2cbor.lua` implements serialize/deserialize. Request: POST to `/service/{service_name}/operation/{op_name}`, `Smithy-Protocol: rpc-v2-cbor` header, `Accept: application/cbor`. Empty input = no body, no Content-Type. Errors identified by `__type` field in CBOR body (full shape ID, strip namespace). Validates `Smithy-Protocol` response header.
**Affects:** Generated clients using rpcv2Cbor protocol.

## 2026-05-04 — Waiter runtime + codegen from @waitable trait
**Context:** Need waiters (polling loops) for operations with the Smithy `@waitable` trait.
**Decision:** Two-part design:
1. **Runtime (`waiter.lua`):** Generic `waiter.wait(client, operation_fn, input, waiter_config, options)` function. `waiter_config` is a table with `acceptors`, `min_delay`, `max_delay` — emitted by codegen as Lua table literals. Acceptor matching supports 4 matcher types: `output` (path eval on output), `inputOutput` (path eval on `{input, output}`), `success` (bool), `errorType` (string match on `err.code`). Path evaluation handles dot-path traversal and `[]` list flattening (covers DynamoDB, EC2, S3 waiter patterns). Comparators: `stringEquals`, `booleanEquals`, `allStringEquals`, `anyStringEquals`. Exponential backoff with jitter between minDelay and maxDelay, capped by `max_wait_time` budget.
2. **Codegen (`WaiterGenerator.java`):** `LuaIntegration` that reads `WaitableTrait` from operations, emits `{ns}/waiters.lua` with `wait_until_{snake_case}` functions and `{ns}/waiters.d.tl` with Teal declarations. Each function captures the acceptor config as a Lua table literal and delegates to `waiter.wait()`. Services without `@waitable` operations produce no waiters file.
**Generated API:** `waiters.wait_until_table_exists(client, input, { max_wait_time = 300 })`
**Affects:** Generated service clients (new waiters.lua file per service with waiters), runtime (new waiter.lua module).

## 2026-05-04 — Config resolver system: LuaIntegration.getConfigResolvers() hook
**Context:** Generated client constructors need to resolve defaults for protocol, signer, HTTP client, retry, and credentials. Some resolvers are generic Smithy concerns, others are SDK-specific (e.g. credential chain).
**Decision:** Added `ConfigResolver` record (requirePath, requireAlias, functionCall) and `getConfigResolvers(LuaContext)` default method on `LuaIntegration`. `DirectedLuaCodegen.generateService()` collects resolvers from all integrations and emits them in the generated `new(cfg)` constructor. Base codegen also detects protocol traits on the service shape and emits the appropriate protocol default. Created `defaults.lua` in runtime with `resolve_signer`, `resolve_http_client`, `resolve_retry_strategy`.
**Affects:** All generated client constructors, aws-sdk-lua codegen (uses this hook for identity_resolver).

## 2026-05-04 — Service namespace uses sdkId from aws.api#service trait
**Context:** `getServiceNamespace()` used the Smithy shape name, causing collisions (RDS/DocDB/Neptune all mapped to `amazonRDSv19`) and ugly names (`aWSSecurityTokenServiceV20110615`).
**Decision:** Use `sdkId` from the `aws.api#service` trait when present, normalized (remove dashes/spaces, lowercase). Falls back to uncapitalized shape name for non-AWS services. Produces clean names: `dynamodb`, `s3`, `sts`, `lambda`.
**Affects:** All generated service client directory names, all require() paths in generated code.

## 2026-05-04 — Codegen emits specific numeric types instead of generic "number"
**Context:** The JSON codec needs to distinguish float/double from integer types for proper formatting (e.g., `1.0` vs `1`, NaN/Infinity as quoted strings).
**Decision:** `toLuaSchemaType` now emits `byte`, `short`, `integer`, `long`, `float`, `double` instead of collapsing all to `number`. The codec already handled these types; only the codegen was collapsing them.
**Affects:** All generated schemas, all codec/protocol implementations (must handle the specific type strings).

## 2026-05-04 — Codegen references top-level schemas for structure/union member targets
**Context:** When a structure member targets another structure or union, codegen was emitting `{ type = "union" }` with no members — the codec couldn't serialize/deserialize the inner shape.
**Decision:** `writeMemberSchema` now emits `M.ShapeName` (a Lua reference to the top-level schema) for structure/union targets. If the member also has traits, uses `setmetatable({ traits = {...} }, { __index = M.ShapeName })`. Lists/maps with structure/union elements emit `member = M.ShapeName` / `value = M.ShapeName`.
**Affects:** All generated schemas, codec implementations (no changes needed — they already walk `schema.members`).

## 2026-05-04 — Codegen emits full member schemas for lists and maps
**Context:** Lists used `member_type = "string"` (a bare string) and maps used `key_type`/`value_type`. The codec expected `member = { type = "string" }` (a schema table).
**Decision:** Lists now emit `member = { type = "..." }` and maps emit `key = { type = "..." }`, `value = { type = "..." }`. These are full schema objects matching what the codec expects.
**Affects:** All generated schemas. Old `member_type`/`key_type`/`value_type` fields no longer emitted.

## 2026-05-04 — Default value population: codegen + runtime
**Context:** Smithy `@default` trait requires clients to populate default values for missing members.
**Decision:** Three parts:
1. **Codegen:** Emits `default = <value>` in member traits. Skips emission when `@clientOptional` is present (non-authoritative generators ignore defaults per spec). Blob defaults are emitted as base64 strings (matching the Smithy model representation).
2. **Serialize:** Defaults applied to nested structures only (not top-level input members). When a structure is explicitly provided (even as `{}`), its nil members get defaults. Top-level input members that are nil stay nil.
3. **Deserialize:** Defaults applied to all structure members. Required members missing from responses get zero-values (error correction): `""` for strings, `false` for booleans, `0` for numbers/timestamps, `""` for blobs, `{}` for lists/maps.
Blob defaults are base64-decoded before use (model stores them as base64).
**Affects:** All codec/protocol implementations, generated schemas.

## 2026-05-04 — ISO 8601 and HTTP-date timestamp formatting in JSON codec
**Context:** The JSON codec only handled epoch-seconds timestamps. Protocol tests require ISO 8601 (`date-time`) and HTTP-date formatting/parsing.
**Decision:** Added `_format_iso8601`, `_format_http_date`, `_parse_iso8601` to `codec/json.lua`. ISO 8601 parsing handles timezone offsets and fractional seconds. Epoch-seconds integers no longer emit trailing `.000`.
**Affects:** All protocols using the JSON codec with non-default timestamp formats.

## 2026-05-04 — Protocol test skip list for unimplemented features
**Context:** Request compression (`@requestCompression`) is not implemented. The corresponding protocol tests fail.
**Decision:** `HttpProtocolTestGenerator` has a static `SKIP_TESTS` set of test IDs. Matching tests emit an empty test body with a skip comment instead of the full test. Currently skips all `SDKAppliedContentEncoding_*` and `SDKAppendsGzipAndIgnoresHttpProvidedEncoding_*` tests.
**Affects:** Protocol test generation only.

## 2026-05-04 — Codegen: awsJson protocol gets service_id, signing_name from sigv4 trait
**Context:** Generated clients passed a bare version string to `awsjson_protocol.new("1.0")`, so `X-Amz-Target` was `.ListTables` instead of `DynamoDB_20120810.ListTables`. Also, `signing_name` used the Smithy shape name (e.g. `dynamodb_20120810`) instead of the `aws.auth#sigv4` trait name (`dynamodb`).
**Decision:** (1) awsJson protocol constructor now receives `{ version = "1.0", service_id = cfg.service_id }`. (2) `signing_name` is resolved from `service.findTrait("aws.auth#sigv4")` → `name` node, falling back to lowercased shape name for non-AWS services.
**Affects:** All generated awsJson clients (service_id fix), all generated clients (signing_name fix).

## 2026-05-04 — Full SRA auth resolution pipeline
**Context:** The client pipeline used flat `identity_resolver` + `signer` + `signing_name` fields. This doesn't support per-operation auth schemes, noAuth, or endpoint-driven signing property overrides.
**Decision:** Implemented the full SRA auth resolution pipeline:
1. **`auth_schemes`** — map of scheme ID → `{ scheme_id, identity_type, signer, identity_resolver(self, identity_resolvers) }`. The auth scheme knows its identity type and looks up the resolver from a separate pool. Not baked in.
2. **`identity_resolvers`** — separate collection on config, keyed by identity type string (e.g. `"aws_credentials"`). The auth scheme asks this collection for a resolver matching its identity type.
3. **`auth_scheme_resolver`** — function that takes an operation and returns ordered list of `{ scheme_id, signer_properties }`. Default is codegen-generated, maps `operation.effective_auth_schemes` to options with `signing_name` (from model) and `signing_region` (from config).
4. **`signing_name`** is NOT a client config field. It lives in `signer_properties` returned by the auth scheme resolver, sourced from the `@sigv4` trait at codegen time.
5. **Endpoint `authSchemes` overrides** — `auth.apply_endpoint_auth_overrides()` reads `endpoint.properties.authSchemes` and overrides `signing_name`/`signing_region` on the selected scheme's signer properties.
6. **noAuth** — built-in `no_auth_scheme` with anonymous identity resolver and no-op signer. Always available when `smithy.api#noAuth` is in the options.
7. **Per-operation effective auth schemes** — codegen emits `effective_auth_schemes` (list of scheme ID strings) per operation from `ServiceIndex.getEffectiveAuthSchemes()`.
8. **Signer** updated to use `props.signing_region` instead of `props.region`.
**Removed:** `config.identity_resolver`, `config.signer`, `config.signing_name`, `defaults.resolve_signer()`.
**Added:** `config.auth_schemes`, `config.identity_resolvers`, `config.auth_scheme_resolver`, `defaults.resolve_auth_schemes()`, `defaults.resolve_identity_resolvers()`.
**Affects:** client.lua, auth.lua, defaults.lua, signer.lua, all codegen, all tests, convergence test, harness test.

## 2026-05-04 — Protocol test infrastructure: per-case counting, all protocols wired, service exclusions

**Context:** Protocol tests were only wired for awsJson and restJson, and the runner counted per-file not per-case. Many tests were silently skipped.
**Decision:** (1) Wire all 6 protocol implementations into the test generator preamble (awsJson, restJson, restXml, awsQuery, ec2Query, rpcv2Cbor). (2) Exclude service-specific test suites that test customizations not protocol behavior: AmazonML, AmazonS3, BackplaneControlService (API Gateway), Glacier. (3) Test runner counts individual PASS/FAIL per test case, not per file.
**Affects:** Protocol test generation, protocoltest/build.gradle.kts exclusion list.

## 2026-05-04 — HTTP binding timestamp defaults by location

**Context:** Smithy spec defines different default timestamp formats depending on where the timestamp appears in the HTTP message.
**Decision:** Default timestamp formats: headers → `http-date`, query params → `date-time` (ISO 8601), URI labels → `date-time`, body → protocol-specific (epoch-seconds for JSON, date-time for XML). The `@timestampFormat` trait on the member or target shape overrides the default. Codegen now emits `timestamp_format` from both member and target shape.
**Affects:** All REST protocol implementations (restjson, restxml), codegen (DirectedLuaCodegen collectTraits).

## 2026-05-04 — Codegen emits @mediaType and @idempotencyToken traits from target shapes

**Context:** `@mediaType` lives on the target shape (e.g. a blob shape), not the member. `@idempotencyToken` is on the member. Both are needed at runtime for correct serialization.
**Decision:** `collectTraits` now accepts the model and checks target shapes for `@timestampFormat` and `@mediaType`. Added `MEDIA_TYPE` to schema.trait constants. `@idempotencyToken` emitted from member.
**Affects:** All generated schemas, protocol implementations that check these traits.

## 2026-05-04 — Protocol test query param assertions use queryParams/forbidQueryParams/requireQueryParams

**Context:** The test generator was asserting `request.url == path` which failed when query params were present. The Smithy protocol test spec separates URL path from query param assertions.
**Decision:** Tests now assert `assert_url_path(request.url, path)` for the path portion, then `assert_query_param` for each expected param, `assert_no_query_param` for forbidden ones, and `assert_has_query_key` for required keys. The operation's `http_path` uses the full URI template from `@http` trait (includes constant query params).
**Affects:** All generated protocol test files, protocol implementations (must handle constant query params in URI template).

## 2026-05-04 — Constant query params from URI template merged at serialize time

**Context:** The `@http` trait URI can include constant query params (e.g. `/path?foo=bar&hello`). These must always appear in the serialized URL.
**Decision:** The restjson/restxml protocol `serialize` splits `http_path` on `?`, parses constant params, and merges them into the query table. A `KEY_ONLY` sentinel distinguishes key-only params (no `=`) from empty-string values (has `=`). `@httpQuery` params take precedence over `@httpQueryParams` map entries.
**Affects:** restjson.lua, restxml.lua (and any future REST protocol).

## 2026-05-04 — Endpoint rules engine: 8 bug fixes for full test coverage

**Context:** Generated endpoint rules tests for 424 AWS services were failing at 373/424 (51 failures). Root causes were in the smithy-lua endpoint rules engine interpreter and partition data.
**Decision:** Fixed 8 issues: (1) Deep-resolve template strings in endpoint properties. (2) Resolve template strings in function arguments (e.g. `"{Region}"` in `stringEquals`). (3) Convert 0-based indices to 1-based in `getAttr`. (4) Fix `isSet` to correctly handle `false` values (Lua truthiness bug with `and/or`). (5) Reject URLs with `#` fragments in `parseURL`. (6) Return empty path (not `/`) for bare URLs in `parseURL`. (7) Enforce minimum 3-char length in `isVirtualHostableS3Bucket`. (8) Preserve empty segments in `parseArn` resource splitting. Also rewrote `partitions.lua` from canonical `partitions.json` (adds eusc partition, global pseudo-regions, correct dualStack support for iso partitions).
**Affects:** `runtime/smithy/endpoint.lua`, `runtime/smithy/endpoint/partitions.lua`, `test/test_endpoint.lua`.

## 2026-05-05 — ECDSA signing: OpenSSL FFI preferred, pure-Lua fallback via lazy resolver
**Context:** Pure-Lua ECDSA P-256 signing works but is slow (scalar multiplication over bigints). OpenSSL is available on most systems and handles this in native code.
**Decision:** `crypto/ecdsa.lua` is now a lazy resolver. On first call to `sign()`, it probes for OpenSSL libcrypto via LuaJIT FFI. If available, locks in `ecdsa_openssl.lua` for the process lifetime. Otherwise falls back to `ecdsa_lua.lua` (the original pure-Lua implementation, unchanged). The public interface (`ecdsa.sign(d, hash_bytes) -> DER`) is unchanged — callers don't know which backend is active. `ecdsa.backend()` returns `"openssl"` or `"lua"` for diagnostics.
**Affects:** Any code that previously required `smithy.crypto.ecdsa` — no API change, but the module is now a resolver rather than the implementation itself. `der_encode` is only on the Lua backend directly; the resolver delegates to `ecdsa_lua` for it.

## 2026-05-05 — Operation interceptors: SRA-aligned hook system in invokeOperation

**Context:** The interceptors field was stubbed in session 4 but never implemented. The SRA defines a comprehensive set of hooks for observing/modifying requests and responses at defined pipeline points.
**Decision:** Implemented operation interceptors matching the SRA hook model:
1. **Interface:** An interceptor is a table with optional hook methods. 19 hooks total: `read_before_execution`, `modify_before_serialization`, `read_before_serialization`, `read_after_serialization`, `modify_before_retry_loop`, `read_before_attempt`, `modify_before_signing`, `read_before_signing`, `read_after_signing`, `modify_before_transmit`, `read_before_transmit`, `read_after_transmit`, `modify_before_deserialization`, `read_before_deserialization`, `read_after_deserialization`, `modify_before_attempt_completion`, `read_after_attempt`, `modify_before_completion`, `read_after_execution`.
2. **Semantics:** `read_*` hooks observe only (return value ignored). `modify_*` hooks return a new value for the field they modify. Completion hooks (`modify_before_attempt_completion`, `modify_before_completion`) receive `(ctx, err)` and return `(output, err)` — they can swallow or replace errors.
3. **Error behavior:** Errors in pre-serialization hooks jump to `modify_before_completion`. Errors in per-attempt hooks jump to `modify_before_attempt_completion`. Matches SRA spec.
4. **Context:** A single context table carries `input`, `operation`, `request`, `response`, `output` — fields populated progressively as the pipeline advances.
5. **Configuration:** `config.interceptors` is a list of interceptor tables. Can be set at client construction or added per-call via plugins.
6. **Performance:** When `interceptors` is nil or empty, no hook overhead — all hook calls are guarded by `if has_interceptors`.
7. **Module:** `runtime/smithy/interceptor.lua` exports `run_read`, `run_modify`, `run_modify_completion`, `run_read_with_error` helpers used by `client.lua`.
**Affects:** client.lua (pipeline now has interceptor hooks), any code that sets `config.interceptors`.

## 2026-05-05 — Dynamic client: runtime model loading without codegen

**Context:** Want to call AWS services without running codegen — just give it a Smithy JSON AST model file.
**Decision:** Single module `runtime/smithy/dynamic.lua` that:
1. Loads a Smithy JSON AST model (file path or pre-parsed table)
2. Converts shapes to runtime schemas using the same `schema.new()` format codegen produces
3. Auto-detects protocol from service traits (awsJson, restJson, restXml, awsQuery, ec2Query, rpcv2Cbor)
4. Auto-detects auth schemes and signing name from `aws.auth#sigv4` trait
5. Supports endpoint rules from model or static `endpoint_url`
6. Exposes `client:call(operationName, input)` and `client:operations()`
7. Lazily builds operation tables on first call (caches them)

**API:**
```lua
local dynamic = require("smithy.dynamic")
local client = dynamic.new({
    model = "path/to/model.json",  -- or a table
    service = "com.example#MyService",  -- optional if single service
    region = "us-east-1",
    endpoint_url = "https://...",  -- or let endpoint rules resolve
})
local result, err = client:call("ListTables", { Limit = 10 })
```

**Key design:** The dynamic client produces the exact same operation tables that codegen produces. It feeds into the same `invokeOperation` pipeline. No new runtime machinery needed.

**Also fixed:** `http/client.lua` had incorrect require paths for backends (`http.curl_ffi` → `smithy.http.curl_ffi`).

**Affects:** New module only. No changes to existing pipeline or protocols.
