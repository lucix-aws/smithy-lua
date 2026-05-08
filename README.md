# smithy-lua

Smithy code generators and client runtime for Teal and Lua.

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

