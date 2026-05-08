# smithy-lua

Smithy code generators and client runtime for Lua and Teal.

## All development work is done in Teal

**This is a teal-first project.**

All runtime code, including unit tests, must be written in Teal. The code
generator (written in Java) must emit Teal code.

## Codegen

This repository implements the client codegen plugin lua-client-codegen.

## Runtime

This Smithy generator aims to be MOSTLY runtime. Having code in the runtime
means you can easily test it, and it's accessible for people to read and
understand.

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

