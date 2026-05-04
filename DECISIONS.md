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