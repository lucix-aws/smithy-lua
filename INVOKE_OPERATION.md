# invokeOperation Contract

The spine of the SDK. Every operation flows through this pipeline.

Reference: [Smithy Reference Architecture — "Implementing a Client Operation"](SmithyReferenceArchitectureDocumentation/smithy_reference_arch/bringing_it_together.tex)

## Signature

```lua
function client:invokeOperation(input, operation, options) -> output, err
```

- `input` — user's input table (modeled members)
- `operation` — static codegen-produced operation table (see below)
- `options` — optional per-call overrides: `{ plugins = { fn, fn, ... } }` or nil

## Client Config

The `client` table carries a `config` field. This is what plugins receive and mutate.

```lua
config = {
    -- == LOCKED: needed for first real call ==

    service_id     = "sts",              -- string: smithy service name
    protocol       = <ClientProtocol>,   -- table with serialize/deserialize (see below)
    http_client    = <fn>,               -- function(request) -> response, err
    endpoint_provider = <fn>,            -- function(params) -> endpoint, err
    identity_resolver = <fn>,            -- function() -> identity, err
    signer         = <fn>,               -- function(request, identity, props) -> request, err
    signing_name   = "sts",              -- string: service signing name
    region         = "us-east-1",        -- string: AWS region

    -- == IMPLEMENTED ==

    retry_strategy = <Retryer|nil>,    -- acquire_token / retry_token / record_success (nil = single attempt)

    -- == STUBBED: come back to these ==

    -- auth_schemes      = {},                 -- keyed by scheme ID, each has identity_resolver + signer
    -- auth_scheme_resolver = <fn>,            -- (config, operation) -> ordered list of scheme IDs
    -- interceptors       = {},                -- list of Interceptor tables
}
```

### Locked fields

| Field | Type | Description |
|---|---|---|
| `service_id` | string | Smithy service name, e.g. `"sts"` |
| `protocol` | ClientProtocol | Serializes input -> HTTP request, deserializes HTTP response -> output |
| `http_client` | function | `(request) -> response, err` |
| `endpoint_provider` | function | `(params) -> endpoint, err` where endpoint is `{ url = string, headers = table? }` |
| `identity_resolver` | function | `() -> identity, err` where identity is `{ access_key, secret_key, session_token? }` |
| `signer` | function | `(request, identity, props) -> request, err` |
| `signing_name` | string | SigV4 service name |
| `region` | string | AWS region |

### Implemented (optional)

| Field | Type | Description |
|---|---|---|
| `retry_strategy` | Retryer or nil | Token-bucket retry. `nil` = single attempt (no retry). |

### Stubbed fields (deferred)

| Field | Notes |
|---|---|
| `auth_schemes` | Full auth scheme resolution per ref arch. For now, single identity_resolver + signer. |
| `auth_scheme_resolver` | Per-service auth scheme selection. For now, always use the one signer. |
| `interceptors` | 17-hook interceptor pipeline per ref arch. For now, no interceptor calls. |

## Operation Table

Static, produced by codegen. One per operation, never mutated.

```lua
operation = {
    -- == LOCKED ==
    name           = "GetCallerIdentity",  -- string: operation name
    input_schema   = <schema>,             -- runtime schema for input shape
    output_schema  = <schema>,             -- runtime schema for output shape
    http_method    = "POST",               -- string: HTTP method
    http_path      = "/",                  -- string: HTTP path pattern

    -- == STUBBED ==
    -- error_schemas  = {},                -- list of modeled error schemas
    -- auth_schemes   = {},                -- per-operation auth override (from @auth trait)
}
```

## ClientProtocol Interface

```lua
protocol = {
    -- Serialize modeled input into an HTTP request.
    -- The returned request has method, path, headers, body set
    -- but NOT the host/endpoint (that comes from endpoint resolution).
    serialize = function(input, operation) -> request, err

    -- Deserialize an HTTP response into modeled output or an error.
    deserialize = function(response, operation) -> output, err
}
```

## Pipeline

Follows the Smithy Reference Architecture ordering. Steps marked `[STUB]` are
placeholders — the pipeline runs without them, they'll be wired in later.

```
invokeOperation(self, input, operation, options):

  -- 1. Config resolution
  config = shallow_copy(self.config)
  if options and options.plugins then
      for _, plugin in ipairs(options.plugins) do
          plugin(config)
      end
  end

  -- [STUB] 2. interceptors: readBeforeExecution
  -- [STUB] 3. interceptors: modifyBeforeSerialization (may mutate input)
  -- [STUB] 4. interceptors: readBeforeSerialization

  -- 5. Serialize
  request, err = config.protocol.serialize(input, operation)
  if err then return nil, err end

  -- [STUB] 6. interceptors: readAfterSerialization
  -- [STUB] 7. interceptors: modifyBeforeRetryLoop (may mutate request)

  -- 8. Retry loop
  -- If config.retry_strategy is set, use it. Otherwise single attempt.
  -- request._path = request.url (stash original path for URL rebuild)
  -- token = config.retry_strategy:acquire_token()

  -- while true:

      -- [STUB] 9a. interceptors: readBeforeAttempt

      -- [STUB] 9b. Resolve auth scheme (for now, use config.identity_resolver + config.signer directly)

      -- 9c. Resolve identity
      identity, err = config.identity_resolver()
      if err then return nil, err end

      -- 9d. Resolve endpoint
      endpoint, err = config.endpoint_provider({ region = config.region })
      if err then return nil, err end

      -- 9e. Apply endpoint to request (rebuild URL from _path each attempt)
      request.url = endpoint.url .. request._path
      if endpoint.headers then
          for k, v in pairs(endpoint.headers) do
              request.headers[k] = v
          end
      end

      -- [STUB] 9f. interceptors: modifyBeforeSigning
      -- [STUB] 9g. interceptors: readBeforeSigning

      -- 9h. Sign
      request, err = config.signer(request, identity, {
          signing_name = config.signing_name,
          region = config.region,
      })
      if err then return nil, err end

      -- [STUB] 9i. interceptors: readAfterSigning
      -- [STUB] 9j. interceptors: modifyBeforeTransmit
      -- [STUB] 9k. interceptors: readBeforeTransmit

      -- 9l. Transmit
      response, err = config.http_client(request)
      if err then return nil, err end

      -- [STUB] 9m. interceptors: readAfterTransmit
      -- [STUB] 9n. interceptors: modifyBeforeDeserialization
      -- [STUB] 9o. interceptors: readBeforeDeserialization

      -- 9p. Deserialize
      output, err = config.protocol.deserialize(response, operation)

      -- [STUB] 9q. interceptors: readAfterDeserialization
      -- [STUB] 9r. interceptors: modifyBeforeAttemptCompletion
      -- [STUB] 9s. interceptors: readAfterAttempt

  -- 10. Classify response for retry
  --   success -> retry_strategy:record_success(token); return output
  --   retryable -> delay = retry_strategy:retry_token(token, err); sleep(delay); continue loop
  --   non-retryable or exhausted -> fall through with error

  -- [STUB] 11. interceptors: modifyBeforeCompletion
  -- [STUB] 12. interceptors: readAfterExecution

  -- 13. Return
  return output, err
```

## Per-Operation Overrides

Users pass `options` as the third argument to an operation method:

```lua
client:getCallerIdentity({}, {
    plugins = {
        function(config)
            -- full mutation access to config
            config.region = "us-west-2"
        end,
    },
})
```

Generated operation code passes it through:

```lua
function Client:getCallerIdentity(input, options)
    return self:invokeOperation(input, {
        name = "GetCallerIdentity",
        input_schema = get_caller_identity_input_schema,
        output_schema = get_caller_identity_output_schema,
        http_method = "POST",
        http_path = "/",
    }, options)
end
```

## Decisions

- **Plugins-only overrides.** No shorthand fields on `options` for now. Plugins receive the
  mutable config copy and can do anything. Sugar deferred to post-hackathon.
- **Single auth path.** No auth scheme resolution for now. `config.identity_resolver` and
  `config.signer` are used directly. Full auth scheme resolver wired later.
- **Retry implemented.** Optional `retry_strategy` field. `nil` = single attempt (backward compat).
  Standard retry: token bucket (500 capacity, 5/10 cost), exponential jitter backoff, max 3 attempts.
- **No interceptors.** All 17 hooks stubbed in the pipeline. Wired later.
- **Endpoint params are minimal.** Just `{ region }` for now. Per-operation input members
  feeding into endpoint params deferred.
