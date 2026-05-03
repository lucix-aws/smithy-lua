# AWS Lua SDK — Constitution & Design Document

## Project Overview

**Goal:** Build a full-featured AWS SDK for Lua in 5 days (Monday–Thursday) using AI-assisted development.

**Runtime target:** LuaJIT (not PUC Lua 5.4). This gives us the `bit` library and FFI if needed, though the goal is to stay pure Lua where possible.

**Reference SDK:** AWS Go SDK v2. Go and Lua share relevant DNA — no classes, multiple returns, explicit error handling, lightweight type systems. Translation patterns should be natural.

**Type story:** Teal `.d.tl` declaration files alongside plain Lua code. Optional — Teal users get type safety, plain Lua users just pass tables. This is a stretch goal, not a blocker.

---

## Timeline

| Day | Focus | Details |
|-----|-------|---------|
| 1 (Mon) | Design & foundations | Finalize contracts, implement SHA-256, HMAC, HTTP client interface, SigV4 |
| 2 (Tue) | Runtime implementation | `invokeOperation` pipeline, core client, integrate all pieces, make one real AWS call |
| 3 (Wed) | Smithy codegen | Build codegen that reads Smithy models and emits Lua. Get one service (S3 or STS) generating end-to-end |
| 4 (Thu) | Breadth & polish | Expand codegen to more services, Teal `.d.tl` emitter, demo script, presentation |

---

## Repository Structure

Two repositories, mirroring the Go SDK's `smithy-go` / `aws-sdk-go-v2` split:

### `smithy-lua` — Smithy client runtime + codegen

The dividing line is **not** "does this know about AWS" — it's "does this know about the **AWS SDK**." Smithy-lua is the generic Smithy client runtime. It knows about AWS protocols (those are Smithy protocols), but not about the SDK's user-facing configuration story.

```
smithy-lua/
├── runtime/                  -- Lua modules (the smithy client runtime)
│   ├── client.lua            -- base client, invokeOperation
│   ├── http.lua              -- HTTP types, reader abstraction, transport interface
│   ├── signer.lua            -- SigV4 signing (Smithy auth scheme)
│   ├── endpoint.lua          -- endpoint rules engine (interpreter)
│   ├── retry.lua             -- retryer interface
│   ├── retry/
│   │   └── standard.lua      -- AWS standard retry implementation (token bucket)
│   ├── auth.lua              -- identity, identity resolver, auth scheme interfaces
│   ├── protocol.lua          -- ClientProtocol interface
│   ├── protocol/             -- protocol implementations
│   │   ├── json.lua          -- awsJson1.0, awsJson1.1
│   │   ├── restjson.lua      -- restJson1
│   │   ├── restxml.lua       -- restXml
│   │   ├── query.lua         -- awsQuery, ec2Query
│   │   └── rpcv2cbor.lua     -- Smithy RPCv2 CBOR
│   ├── codec/                -- format-specific codecs
│   │   ├── json.lua          -- JSON codec (ShapeSerializer/ShapeDeserializer)
│   │   ├── xml.lua           -- XML codec
│   │   └── cbor.lua          -- CBOR codec
│   ├── schema.lua            -- runtime Schema type
│   ├── serde.lua             -- ShapeSerializer/ShapeDeserializer interfaces
│   ├── crypto/
│   │   ├── sha256.lua        -- pure Lua SHA-256
│   │   └── hmac.lua          -- HMAC-SHA-256
│   ├── error.lua             -- generic error types
│   └── ...
├── codegen/                  -- Java (Smithy codegen plugin, emits Lua)
│   ├── build.gradle.kts
│   └── src/main/java/...
└── README.md
```

### `aws-sdk-lua` — The AWS SDK experience layer

The SDK repo owns the user experience: configuration, credential resolution, and generated service clients.

```
aws-sdk-lua/
├── runtime/                  -- SDK-specific runtime
│   ├── config.lua            -- ~/.aws/config + ~/.aws/credentials parsing
│   ├── credentials.lua       -- default credential provider chain
│   ├── credentials/          -- individual credential providers
│   │   ├── static.lua        -- explicit credentials
│   │   ├── environment.lua   -- AWS_ACCESS_KEY_ID, etc.
│   │   ├── shared_config.lua -- shared credentials/config file profiles
│   │   ├── sso.lua           -- SSO token provider
│   │   ├── web_identity.lua  -- AssumeRoleWithWebIdentity
│   │   ├── ecs.lua           -- ECS container credentials
│   │   └── imds.lua          -- EC2 instance metadata
│   └── ...
├── codegen/                  -- Java (AWS SDK codegen plugins, extends smithy-lua codegen)
│   ├── build.gradle.kts
│   └── src/main/java/...
├── service/                  -- generated service clients
│   ├── s3/
│   ├── sts/
│   ├── dynamodb/
│   └── ...
└── README.md
```

---

## Dependencies

The SDK aims for minimal dependencies:

- **SHA-256:** Pure Lua implementation (vendor or generate). Performance doesn't matter.
- **HMAC-SHA-256:** ~15 lines on top of SHA-256. Pure Lua.
- **SigV4:** String formatting + SHA-256/HMAC. Pure Lua. Well-documented algorithm with test vectors.
- **JSON:** cjson or dkjson (widely available, already standard in LuaJIT ecosystems).
- **HTTP client:** Behind a pluggable interface. Pick whatever works at runtime (luasocket, lua-http, lua-resty-http, FFI to libcurl). The SDK doesn't care.

**No native/C dependencies required for core functionality.** The HTTP client backend is the only place where a native dependency might come in, and it's swappable.

---

## Architecture

### Serialization: Schema-Serde

The SDK follows the **schema-serde** approach (per the accepted SEP "Serialization and Schema Decoupling"). Instead of generating per-operation serializer/deserializer functions, codegen produces **schemas** — lightweight runtime descriptions of shapes — and the **protocol implementation** handles serialization generically using those schemas.

Key concepts:
- **Schema** — runtime data object describing a shape: its type, members, and serialization-relevant traits (jsonName, xmlName, timestampFormat, httpHeader, etc.)
- **ShapeSerializer / ShapeDeserializer** — format-agnostic interfaces for writing/reading the Smithy data model
- **Codec** — pairs a ShapeSerializer and ShapeDeserializer for a specific format (JSON, XML, CBOR)
- **ClientProtocol** — uses codecs to serialize requests and deserialize responses for a specific protocol (awsJson1.0, restJson1, restXml, etc.)

In Lua (dynamically typed), schemas alone may be sufficient for serde — we can walk tables dynamically without the consumer/builder patterns that typed languages need.

### What codegen produces per service

1. **Schemas** — per-shape schema declarations (shape type, members, traits)
2. **Client constructor** — wires service-level config (protocol, auth, endpoint ruleset)
3. **Per-operation functions** — thin wiring that passes input + operation schema to `invokeOperation`
4. **Endpoint ruleset** — emitted as a Lua table literal (not JSON loaded at runtime)

### Operation Pipeline

The runtime exposes a generic `invokeOperation` function. The pipeline:

```
serialize (protocol.serializeRequest)
  └─ retry loop:
       ├─ resolve auth scheme
       ├─ resolve endpoint
       ├─ sign
       ├─ send request (transport)
       ├─ deserialize (protocol.deserializeResponse)
       └─ if error: consult retryer → delay → loop
```

Everything after serialization lives inside the retry loop — endpoint resolution, signing, sending, and deserialization all happen per-attempt.

### invokeOperation

```lua
function invokeOperation(client, input, operation) -> output, err
```

Where:
- `client` carries: protocol (ClientProtocol), transport (HTTP client), retryer, identity resolver, region, endpoint ruleset
- `operation` carries: input schema, output schema, operation name, HTTP method/path

The protocol does the heavy lifting for serde, not per-operation functions.

### Client Construction

Service-level configuration is set at client construction time. Each service's generated code provides:

```lua
function new(config)
    return base_client.new({
        service = "s3",
        protocol = restxml_protocol,
        endpoint_rules = s3_endpoint_rules,
        signing_name = "s3",
        -- ...
    }, config)
end
```

### Generated Operation Code

Each operation is thin — just schema wiring:

```lua
function Client:putObject(input)
    return self:invokeOperation(input, {
        name = "PutObject",
        input_schema = put_object_input_schema,
        output_schema = put_object_output_schema,
        http_method = "PUT",
        http_path = "/{Bucket}/{Key+}",
    })
end
```

---

## Endpoint Resolution

Full **Smithy endpoint rulesets**, not hardcoded URL patterns. Every AWS service model ships with an `endpointRuleSet` trait — a DSL that evaluates to a URL given parameters (region, FIPS, dual-stack, service-specific context params).

- **Codegen (Java)** reads the `endpointRuleSet` trait and emits it as a **Lua table literal** (no JSON parsing at runtime).
- **smithy-lua runtime** has a **rules engine interpreter** that evaluates the ruleset given parameters and returns `{ url, auth_schemes, headers }`.
- The rules engine implements the standard built-in functions: `isSet`, `getAttr`, `parseURL`, `substring`, `stringEquals`, `booleanEquals`, `uriEncode`, `aws.partition`, etc.
- Partition data (region-to-partition mapping) ships as a Lua table alongside the rules engine.

```lua
-- Generated: service/s3/endpoint_rules.lua
return {
    parameters = { ... },
    rules = { ... },
}

-- Runtime: smithy-lua/runtime/endpoint.lua
function resolve(ruleset, params) -> { url, auth_schemes, headers }
```

---

## Retry Strategy

A **Retryer interface** in smithy-lua runtime, with the **AWS standard retry** as the concrete implementation.

### Retryer Interface

```lua
{
    acquire_token = function(self) -> token, err,
    retry_token = function(self, token, err) -> delay, err,
    record_success = function(self, token),
}
```

### AWS Standard Retry

- Max 3 attempts (configurable)
- Exponential backoff with jitter
- Token bucket for circuit-breaking (spend tokens on retries, earn back on success)
- Retries on: throttling errors (429, `Throttling`, `TooManyRequests`, etc.), transient errors (500, 502, 503, 504), connection errors
- No adaptive mode (out of scope)

Lives in `smithy-lua/runtime/retry/standard.lua`.

---

## Credential Resolution

### Abstractions (smithy-lua runtime)

- `Identity` — base concept
- `IdentityResolver` interface — returns an identity
- SigV4 credential identity type: `{ access_key, secret_key, session_token, expiration }`
- Auth scheme interfaces — how to resolve identity + how to sign with it

### Default Credential Chain (aws-sdk-lua runtime)

Full chain matching existing AWS SDKs, implemented in priority order:

1. **Static credentials** — explicit in config
2. **Environment variables** — `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`
3. **SSO token provider** — SSO credentials via cached token
4. **Web identity token** — `AWS_WEB_IDENTITY_TOKEN_FILE` + STS AssumeRoleWithWebIdentity
5. **Shared credentials/config file** — profiles, `role_arn` with assume-role, `credential_process`
6. **ECS container credentials** — `AWS_CONTAINER_CREDENTIALS_*`
7. **IMDS** — EC2 instance metadata service

The chain structure is complete from day one. Individual providers are implemented as time permits, with static, environment, and shared config file as the priority for the hackathon.

---

## HTTP Client Interface

### Reader Abstraction

A **reader** is the fundamental I/O primitive, equivalent to Go's `io.Reader`:

```lua
-- A reader is a function:
function() -> chunk, err
-- Returns a string chunk on each call
-- Returns nil when done (EOF)
-- Returns nil, err on failure
```

### Helper

```lua
function string_reader(s)
    local done = false
    return function()
        if done then return nil end
        done = true
        return s
    end
end
```

### Request

```lua
{
    method = "POST",
    url = "https://s3.us-east-1.amazonaws.com/…",
    headers = {
        ["Content-Type"] = "application/json",
    },
    body = reader,
}
```

### Response

```lua
{
    status_code = 200,
    headers = {
        ["Content-Type"] = "application/xml",
    },
    body = reader,
}
```

### HTTP Client Interface

```lua
function http_client(request) -> response, err
```

Body is always a reader on both request and response. Never a raw string — use `string_reader()` to wrap strings. One type, one interface, no branching.

The HTTP client is pluggable. The SDK accepts any function/object conforming to this interface. Implementations can wrap luasocket, lua-resty-http, libcurl via FFI, etc.

---

## Error Model

### Base Error

Every error is a Lua table with at minimum:

```lua
{
    type = "api",       -- category: "api" | "http" | "sdk"
    code = "NoSuchBucket",
    message = "The specified bucket does not exist",
}
```

### Error Categories

- **`api`**: The service returned an error response. May have additional deserialized fields.
- **`http`**: Transport-level failure (connection refused, timeout, DNS failure).
- **`sdk`**: Client-side error (serialization failure, invalid input).

### API Errors with Extra Fields

Service-specific errors can have additional deserialized members:

```lua
{
    type = "api",
    code = "InvalidObjectState",
    message = "...",
    StorageClass = "GLACIER",
    AccessTier = "...",
}
```

### Error Checking

```lua
local result, err = s3:getObject(input)
if err then
    if err.type == "api" then
        print("API error:", err.code, err.message)
    elseif err.type == "http" then
        print("Connection failed:", err.message)
    end
end
```

### Return Convention

All operations return `result, err`:
- Success: `result` is populated, `err` is nil
- Failure: `result` is nil, `err` is an error table

---

## Teal Type Strategy

### Approach

Generate `.d.tl` declaration files alongside Lua code. The SDK itself is plain Lua. Teal users get type safety by importing the declarations.

### Priority

Teal `.d.tl` generation is a **stretch goal**. Build everything in plain Lua first. Add Teal declaration emitter to codegen late in the week if time permits.

---

## User-Facing API Example

```lua
local aws = require("aws")
local s3 = require("aws.s3")

local client = s3.new({
    region = "us-east-1",
})

local resp, err = client:putObject({
    Bucket = "my-bucket",
    Key = "hello.txt",
    Body = "hello world",
})
if err then
    print("failed:", err.code, err.message)
    return
end
print("etag:", resp.ETag)
```

---

## Codegen

### Language: Java

The codegen is written in **Java** using the **Smithy codegen framework** (`software.amazon.smithy:smithy-codegen-core`).

Reasons:
1. Smithy's codegen framework is Java-native — model loading, symbol resolution, shape traversal, dependency graphs, and plugin architecture come for free.
2. Model parsing is a solved problem — the Smithy Java libraries handle model merging, trait resolution, and validation.
3. AI produces higher-quality Java than Lua due to deeper training data.

The codegen is a standard Smithy codegen plugin. It takes Smithy models as input and emits `.lua` files. Both `smithy-lua/codegen/` and `aws-sdk-lua/codegen/` are Java projects — the latter extends the former with AWS SDK-specific codegen plugins.

Users consuming the SDK do not need Java — it's a build-time concern only.

---

## AI Workflow

### Constitution-Driven

This document is the constitution. Every AI agent session should reference it to maintain consistency across parallel work streams.

### Parallel Work Strategy

- **Design serially first.** Nail down interfaces and contracts before fanning out.
- **Then parallelize independent modules:** SHA-256, HTTP client, SigV4 signing can all be built concurrently.
- **Integration after.** Merge and test before moving to codegen.

### Agent Task Scoping

Each agent session should:
1. Receive this constitution doc
2. Be scoped to a specific module/task
3. Follow the conventions defined here
4. Write tests alongside implementation
5. Not deviate from interface contracts without flagging it

### Reference Materials

- **Go SDK v2** — primary code reference for patterns and architecture
- **Smithy Java** — reference for schema-serde implementation
- **Schema-Serde SEP** — specification for serialization approach (`AwsDrSeps/seps/accepted/shared/schema-serde/`)
- **Smithy endpoint rules spec** — for rules engine implementation
- **AWS SigV4 documentation + test vectors** — for signing implementation
- **DR SEPs** — credential resolution, retry, and other behavioral specifications (`AwsDrSeps/seps/`)
