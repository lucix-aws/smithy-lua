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
