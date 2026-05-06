# smithy-lua

Hackathon project May 2026.

SDKs take a long time to go from zero lines of code to GA. The goal of this
project is to see just how much generative AI tools can accelerate that
process.

Like other Smithy-based SDKs, this is done in two repos, though this one aims
to own ~90% of the important logic. The generated AWS SDKs are over at
[aws-sdk-lua](https://github.com/lucix-aws/aws-sdk-lua).

Until the hackathon is complete this README primarily serves as an active
progress tracker.

## Codegen

This repository implements the lua client codegen plugin lua-client-codegen.

## Runtime

Smithy-lua aims to be MOSTLY runtime. Having code in the runtime means you can
easily test it, and it's accessible for people to read and understand.

```
runtime/smithy/
  codec/       -- format-specific codecs (JSON, XML, CBOR)
  crypto/      -- SHA-256, HMAC, ECDSA, P-256 curve math
  endpoint/    -- endpoint ruleset engine
  http/        -- HTTP client backends (libcurl FFI, curl subprocess)
  json/        -- pure Lua JSON encoder/decoder
  protocol/    -- protocol implementations
  retry/       -- retry interface with one implementation: AWS-standard
```

### InvokeOperation

Every operation goes through a single runtime `invokeOperation`. Generated
operations are basically just wrappers that configure the parameters into it.

```lua
function Client:listTables(input, options)
    return self:invokeOperation(input, {
        name = "ListTables",
        input_schema = list_tables_input,
        output_schema = list_tables_output,
        http_method = "POST",
        http_path = "/",
        context_params = { ... },
        effective_auth_schemes = { "aws.auth#sigv4" },
    }, options)
end
```

Dynamic clients should in theory be possible through this API, we'd just have
to support a model-loader etc.

### Protocol Tests

| Protocol | Pass/Total | Rate |
|----------|-----------|------|
| ec2Protocol | **59/59** | **100%** |
| jsonProtocol (awsJson 1.1) | **117/117** | **100%** |
| jsonRpc10 (awsJson 1.0) | **66/66** | **100%** |
| queryProtocol | **76/76** | **100%** |
| restJsonProtocol | **241/241** | **100%** |
| restXmlProtocol | **178/178** | **100%** |
| restXmlProtocolNamespace | **2/2** | **100%** |
| rpcV2Protocol (CBOR) | **68/68** | **100%** |
| queryCompatibleJsonRpc10 | **3/3** | **100%** |
| queryCompatibleRpcV2Protocol | **3/3** | **100%** |
| nonQueryCompatibleRpcV2Protocol | **1/1** | **100%** |
| **Total** | **814/814** | **100%** |

## Hackathon Progress

All of this was done on Opus 4.6.

### Day 1

Kiro credits: 2084.55

(this list was AI-generated from SESSIONS.json)

- Full operation pipeline: serialize, retry loop (endpoint resolve, sign, send, deserialize), error classification
- All 6 AWS protocols: awsJson 1.0/1.1, restJson1, restXml, awsQuery/ec2Query, rpcv2Cbor
- Schema-serde architecture: codegen emits schemas, runtime does serde generically
- SigV4 signing: pure Lua (SHA-256 + HMAC via LuaJIT `bit` library)
- Endpoint rules engine: full Smithy ruleset interpreter, 424/424 AWS service endpoint tests passing
- AWS standard retry: token bucket, exponential backoff with jitter, throttle/transient/timeout classification
- Full SRA auth resolution: per-operation auth schemes, endpoint auth overrides, noAuth
- Codecs: JSON (pure Lua), XML (pure Lua), CBOR (LuaJIT FFI)
- Paginators: runtime engine + codegen from `@paginated` trait
- Waiters: runtime engine + codegen from `@waitable` trait
- Teal declarations: `.d.tl` files for all runtime modules and generated code
- 424 generated service clients (in aws-sdk-lua)
- Real AWS calls: DynamoDB ListTables through the full pipeline (codegen client, awsJson 1.0, SigV4, env creds, libcurl FFI)
- 620/707 Smithy protocol test cases passing (~88%)

### Day 2

Kiro credits: 1392.38

(this list was AI-generated from SESSIONS.json)

- Protocol tests: 620/707 → 814/814 (100% pass rate across all protocols)
- Schema system refactor: formal ShapeId, Trait types, prelude schemas, proper container API
- SigV4a signing: ECDSA P-256 with OpenSSL FFI backend (pure Lua fallback)
- Event streams: output-only streaming support (binary frame decoder, curl_multi HTTP client, Bedrock ConverseStream verified)
- Operation interceptors: full SRA hook model (19 hooks, zero overhead when unused)
- Dynamic client: load Smithy JSON AST models at runtime, call operations without codegen
- aws-crt-lua: CRT HTTP client PoC via LuaJIT FFI (highest-priority backend in resolver)
- Automated model updates: GitHub Actions workflow syncing from api-models-aws daily
- Teal-native runtime exploration: proof-of-concept converting runtime source to .tl (branch pushed, not merged)
