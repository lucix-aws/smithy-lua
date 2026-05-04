-- Test: runtime/endpoint.lua
-- Run: luajit test/test_endpoint.lua

package.path = "runtime/?.lua;runtime/?/init.lua;" .. package.path

local endpoint = require("smithy.endpoint")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        pass = pass + 1
        print("PASS: " .. name)
    else
        fail = fail + 1
        print("FAIL: " .. name .. "\n  " .. tostring(err))
    end
end

local function assert_eq(a, b, msg)
    if a ~= b then
        error((msg or "assert_eq") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2)
    end
end

local function assert_truthy(a, msg)
    if not a then error((msg or "assert_truthy") .. ": got falsy", 2) end
end

local function assert_nil(a, msg)
    if a ~= nil then error((msg or "assert_nil") .. ": expected nil, got " .. tostring(a), 2) end
end

---------------------------------------------------------------------------
-- Basic resolve: simple endpoint rule
---------------------------------------------------------------------------

test("resolve: simple endpoint", function()
    local ruleset = {
        parameters = {
            Region = { type = "string", required = true },
        },
        rules = {
            {
                type = "endpoint",
                conditions = {},
                endpoint = { url = "https://{Region}.example.com" },
            },
        },
    }
    local result, err = endpoint.resolve(ruleset, { Region = "us-east-1" })
    assert_nil(err)
    assert_eq(result.url, "https://us-east-1.example.com")
end)

test("resolve: missing required param", function()
    local ruleset = {
        parameters = {
            Region = { type = "string", required = true },
        },
        rules = {},
    }
    local result, err = endpoint.resolve(ruleset, {})
    assert_nil(result)
    assert_truthy(err:find("required"), err)
end)

test("resolve: default param value", function()
    local ruleset = {
        parameters = {
            Region = { type = "string", required = true, default = "us-west-2" },
        },
        rules = {
            {
                type = "endpoint",
                conditions = {},
                endpoint = { url = "https://{Region}.example.com" },
            },
        },
    }
    local result = endpoint.resolve(ruleset, {})
    assert_eq(result.url, "https://us-west-2.example.com")
end)

---------------------------------------------------------------------------
-- Error rules
---------------------------------------------------------------------------

test("resolve: error rule", function()
    local ruleset = {
        parameters = {},
        rules = {
            {
                type = "error",
                conditions = {},
                error = "this service is not available",
            },
        },
    }
    local result, err = endpoint.resolve(ruleset, {})
    assert_nil(result)
    assert_eq(err, "this service is not available")
end)

test("resolve: error rule with template", function()
    local ruleset = {
        parameters = { Region = { type = "string", required = true } },
        rules = {
            {
                type = "error",
                conditions = {},
                error = "no endpoint for {Region}",
            },
        },
    }
    local _, err = endpoint.resolve(ruleset, { Region = "mars-1" })
    assert_eq(err, "no endpoint for mars-1")
end)

---------------------------------------------------------------------------
-- Tree rules
---------------------------------------------------------------------------

test("resolve: tree rule", function()
    local ruleset = {
        parameters = {
            Region = { type = "string", required = true },
            UseFIPS = { type = "boolean", required = true, default = false },
        },
        rules = {
            {
                type = "tree",
                conditions = {
                    { fn = "booleanEquals", argv = { { ref = "UseFIPS" }, true } },
                },
                rules = {
                    {
                        type = "endpoint",
                        conditions = {},
                        endpoint = { url = "https://{Region}.fips.example.com" },
                    },
                },
            },
            {
                type = "endpoint",
                conditions = {},
                endpoint = { url = "https://{Region}.example.com" },
            },
        },
    }
    local r1 = endpoint.resolve(ruleset, { Region = "us-east-1", UseFIPS = true })
    assert_eq(r1.url, "https://us-east-1.fips.example.com")

    local r2 = endpoint.resolve(ruleset, { Region = "us-east-1", UseFIPS = false })
    assert_eq(r2.url, "https://us-east-1.example.com")
end)

---------------------------------------------------------------------------
-- Condition assign
---------------------------------------------------------------------------

test("resolve: condition assign", function()
    local ruleset = {
        parameters = {
            Endpoint = { type = "string" },
        },
        rules = {
            {
                type = "endpoint",
                conditions = {
                    { fn = "isSet", argv = { { ref = "Endpoint" } } },
                    { fn = "parseURL", argv = { { ref = "Endpoint" } }, assign = "url" },
                },
                endpoint = { url = "{url#scheme}://{url#authority}/custom" },
            },
            {
                type = "endpoint",
                conditions = {},
                endpoint = { url = "https://default.example.com" },
            },
        },
    }
    local r1 = endpoint.resolve(ruleset, { Endpoint = "https://my.host:8443/base" })
    assert_eq(r1.url, "https://my.host:8443/custom")

    local r2 = endpoint.resolve(ruleset, {})
    assert_eq(r2.url, "https://default.example.com")
end)

---------------------------------------------------------------------------
-- Standard library: isSet
---------------------------------------------------------------------------

test("fn: isSet true", function()
    local ruleset = {
        parameters = { Foo = { type = "string" } },
        rules = {
            { type = "endpoint", conditions = { { fn = "isSet", argv = { { ref = "Foo" } } } },
              endpoint = { url = "https://yes.com" } },
            { type = "endpoint", conditions = {}, endpoint = { url = "https://no.com" } },
        },
    }
    assert_eq(endpoint.resolve(ruleset, { Foo = "bar" }).url, "https://yes.com")
    assert_eq(endpoint.resolve(ruleset, {}).url, "https://no.com")
end)

---------------------------------------------------------------------------
-- Standard library: stringEquals, booleanEquals, not
---------------------------------------------------------------------------

test("fn: stringEquals", function()
    local ruleset = {
        parameters = { Region = { type = "string", required = true } },
        rules = {
            { type = "endpoint",
              conditions = { { fn = "stringEquals", argv = { { ref = "Region" }, "us-east-1" } } },
              endpoint = { url = "https://special.com" } },
            { type = "endpoint", conditions = {}, endpoint = { url = "https://default.com" } },
        },
    }
    assert_eq(endpoint.resolve(ruleset, { Region = "us-east-1" }).url, "https://special.com")
    assert_eq(endpoint.resolve(ruleset, { Region = "eu-west-1" }).url, "https://default.com")
end)

test("fn: not", function()
    local ruleset = {
        parameters = { UseFIPS = { type = "boolean", required = true, default = false } },
        rules = {
            { type = "endpoint",
              conditions = { { fn = "not", argv = { { ref = "UseFIPS" } } } },
              endpoint = { url = "https://normal.com" } },
            { type = "endpoint", conditions = {}, endpoint = { url = "https://fips.com" } },
        },
    }
    assert_eq(endpoint.resolve(ruleset, { UseFIPS = false }).url, "https://normal.com")
    assert_eq(endpoint.resolve(ruleset, { UseFIPS = true }).url, "https://fips.com")
end)

---------------------------------------------------------------------------
-- Standard library: getAttr
---------------------------------------------------------------------------

test("fn: getAttr nested", function()
    local ruleset = {
        parameters = { Endpoint = { type = "string" } },
        rules = {
            { type = "endpoint",
              conditions = {
                  { fn = "isSet", argv = { { ref = "Endpoint" } } },
                  { fn = "parseURL", argv = { { ref = "Endpoint" } }, assign = "u" },
              },
              endpoint = { url = "{u#scheme}://custom" } },
            { type = "endpoint", conditions = {}, endpoint = { url = "https://fallback" } },
        },
    }
    assert_eq(endpoint.resolve(ruleset, { Endpoint = "http://foo.com" }).url, "http://custom")
end)

---------------------------------------------------------------------------
-- Standard library: isValidHostLabel
---------------------------------------------------------------------------

test("fn: isValidHostLabel", function()
    local ruleset = {
        parameters = { Bucket = { type = "string", required = true } },
        rules = {
            { type = "endpoint",
              conditions = { { fn = "isValidHostLabel", argv = { { ref = "Bucket" }, false } } },
              endpoint = { url = "https://{Bucket}.s3.amazonaws.com" } },
            { type = "endpoint", conditions = {},
              endpoint = { url = "https://s3.amazonaws.com/{Bucket}" } },
        },
    }
    assert_eq(endpoint.resolve(ruleset, { Bucket = "my-bucket" }).url,
        "https://my-bucket.s3.amazonaws.com")
    assert_eq(endpoint.resolve(ruleset, { Bucket = "INVALID..bucket" }).url,
        "https://s3.amazonaws.com/INVALID..bucket")
end)

---------------------------------------------------------------------------
-- Standard library: parseURL
---------------------------------------------------------------------------

test("fn: parseURL basic", function()
    local ruleset = {
        parameters = { Endpoint = { type = "string", required = true } },
        rules = {
            { type = "endpoint",
              conditions = {
                  { fn = "parseURL", argv = { { ref = "Endpoint" } }, assign = "u" },
              },
              endpoint = { url = "{u#scheme}://{u#authority}{u#normalizedPath}svc" } },
        },
    }
    local r = endpoint.resolve(ruleset, { Endpoint = "https://example.com:8443/base" })
    assert_eq(r.url, "https://example.com:8443/base/svc")
end)

test("fn: parseURL rejects query", function()
    local ruleset = {
        parameters = { Endpoint = { type = "string", required = true } },
        rules = {
            { type = "endpoint",
              conditions = {
                  { fn = "parseURL", argv = { { ref = "Endpoint" } }, assign = "u" },
              },
              endpoint = { url = "ok" } },
            { type = "error", conditions = {}, error = "bad url" },
        },
    }
    local _, err = endpoint.resolve(ruleset, { Endpoint = "https://example.com?q=1" })
    assert_eq(err, "bad url")
end)

test("fn: parseURL isIp", function()
    local ruleset = {
        parameters = { Endpoint = { type = "string", required = true } },
        rules = {
            { type = "endpoint",
              conditions = {
                  { fn = "parseURL", argv = { { ref = "Endpoint" } }, assign = "u" },
                  { fn = "booleanEquals", argv = { { fn = "getAttr", argv = { { ref = "u" }, "isIp" } }, true } },
              },
              endpoint = { url = "https://ip-endpoint" } },
            { type = "endpoint", conditions = {}, endpoint = { url = "https://host-endpoint" } },
        },
    }
    assert_eq(endpoint.resolve(ruleset, { Endpoint = "https://127.0.0.1" }).url, "https://ip-endpoint")
    assert_eq(endpoint.resolve(ruleset, { Endpoint = "https://example.com" }).url, "https://host-endpoint")
end)

---------------------------------------------------------------------------
-- Standard library: substring
---------------------------------------------------------------------------

test("fn: substring forward", function()
    local ruleset = {
        parameters = { Input = { type = "string", required = true } },
        rules = {
            { type = "endpoint",
              conditions = {
                  { fn = "substring", argv = { { ref = "Input" }, 0, 4, false }, assign = "sub" },
              },
              endpoint = { url = "https://{sub}.example.com" } },
            { type = "error", conditions = {}, error = "substring failed" },
        },
    }
    assert_eq(endpoint.resolve(ruleset, { Input = "abcdefgh" }).url, "https://abcd.example.com")
end)

test("fn: substring reverse", function()
    local ruleset = {
        parameters = { Input = { type = "string", required = true } },
        rules = {
            { type = "endpoint",
              conditions = {
                  { fn = "substring", argv = { { ref = "Input" }, 0, 4, true }, assign = "sub" },
              },
              endpoint = { url = "https://{sub}.example.com" } },
            { type = "error", conditions = {}, error = "substring failed" },
        },
    }
    assert_eq(endpoint.resolve(ruleset, { Input = "abcdefgh" }).url, "https://efgh.example.com")
end)

test("fn: substring too short returns nil", function()
    local ruleset = {
        parameters = { Input = { type = "string", required = true } },
        rules = {
            { type = "endpoint",
              conditions = {
                  { fn = "substring", argv = { { ref = "Input" }, 0, 10, false }, assign = "sub" },
              },
              endpoint = { url = "https://ok" } },
            { type = "error", conditions = {}, error = "too short" },
        },
    }
    local _, err = endpoint.resolve(ruleset, { Input = "abc" })
    assert_eq(err, "too short")
end)

---------------------------------------------------------------------------
-- Standard library: uriEncode
---------------------------------------------------------------------------

test("fn: uriEncode", function()
    local ruleset = {
        parameters = { Key = { type = "string", required = true } },
        rules = {
            { type = "endpoint",
              conditions = {
                  { fn = "uriEncode", argv = { { ref = "Key" } }, assign = "encoded" },
              },
              endpoint = { url = "https://s3.amazonaws.com/{encoded}" } },
        },
    }
    assert_eq(endpoint.resolve(ruleset, { Key = "hello world/file" }).url,
        "https://s3.amazonaws.com/hello%20world%2Ffile")
end)

---------------------------------------------------------------------------
-- Standard library: split
---------------------------------------------------------------------------

test("fn: split unlimited", function()
    local ruleset = {
        parameters = { Name = { type = "string", required = true } },
        rules = {
            { type = "endpoint",
              conditions = {
                  { fn = "split", argv = { { ref = "Name" }, "--", 0 }, assign = "parts" },
              },
              endpoint = { url = "https://{parts#[1]}.example.com" } },
        },
    }
    assert_eq(endpoint.resolve(ruleset, { Name = "a--b--c" }).url, "https://a.example.com")
end)

test("fn: split with limit", function()
    local ruleset = {
        parameters = { Name = { type = "string", required = true } },
        rules = {
            { type = "endpoint",
              conditions = {
                  { fn = "split", argv = { { ref = "Name" }, "--", 2 }, assign = "parts" },
              },
              endpoint = { url = "https://{parts#[2]}.example.com" } },
        },
    }
    assert_eq(endpoint.resolve(ruleset, { Name = "a--b--c" }).url, "https://b--c.example.com")
end)

---------------------------------------------------------------------------
-- Standard library: coalesce
---------------------------------------------------------------------------

test("fn: coalesce picks first set", function()
    local ruleset = {
        parameters = {
            Custom = { type = "string" },
            Default = { type = "string", required = true, default = "fallback" },
        },
        rules = {
            { type = "endpoint",
              conditions = {
                  { fn = "coalesce", argv = { { ref = "Custom" }, { ref = "Default" } }, assign = "ep" },
              },
              endpoint = { url = "https://{ep}.example.com" } },
        },
    }
    assert_eq(endpoint.resolve(ruleset, { Custom = "override" }).url, "https://override.example.com")
    assert_eq(endpoint.resolve(ruleset, {}).url, "https://fallback.example.com")
end)

---------------------------------------------------------------------------
-- Standard library: ite
---------------------------------------------------------------------------

test("fn: ite", function()
    local ruleset = {
        parameters = {
            UseFIPS = { type = "boolean", required = true, default = false },
        },
        rules = {
            { type = "endpoint",
              conditions = {
                  { fn = "ite", argv = { { ref = "UseFIPS" }, "-fips", "" }, assign = "suffix" },
              },
              endpoint = { url = "https://svc{suffix}.example.com" } },
        },
    }
    assert_eq(endpoint.resolve(ruleset, { UseFIPS = true }).url, "https://svc-fips.example.com")
    assert_eq(endpoint.resolve(ruleset, { UseFIPS = false }).url, "https://svc.example.com")
end)

---------------------------------------------------------------------------
-- AWS: aws.partition
---------------------------------------------------------------------------

test("fn: aws.partition us-east-1", function()
    local ruleset = {
        parameters = { Region = { type = "string", required = true } },
        rules = {
            { type = "endpoint",
              conditions = {
                  { fn = "aws.partition", argv = { { ref = "Region" } }, assign = "p" },
              },
              endpoint = { url = "https://svc.{Region}.{p#dnsSuffix}" } },
        },
    }
    assert_eq(endpoint.resolve(ruleset, { Region = "us-east-1" }).url,
        "https://svc.us-east-1.amazonaws.com")
end)

test("fn: aws.partition cn region", function()
    local ruleset = {
        parameters = { Region = { type = "string", required = true } },
        rules = {
            { type = "endpoint",
              conditions = {
                  { fn = "aws.partition", argv = { { ref = "Region" } }, assign = "p" },
              },
              endpoint = { url = "https://svc.{Region}.{p#dnsSuffix}" } },
        },
    }
    assert_eq(endpoint.resolve(ruleset, { Region = "cn-north-1" }).url,
        "https://svc.cn-north-1.amazonaws.com.cn")
end)

test("fn: aws.partition gov region", function()
    local ruleset = {
        parameters = { Region = { type = "string", required = true } },
        rules = {
            { type = "endpoint",
              conditions = {
                  { fn = "aws.partition", argv = { { ref = "Region" } }, assign = "p" },
              },
              endpoint = { url = "https://svc.{Region}.{p#dnsSuffix}" } },
        },
    }
    assert_eq(endpoint.resolve(ruleset, { Region = "us-gov-west-1" }).url,
        "https://svc.us-gov-west-1.amazonaws.com")
end)

test("fn: aws.partition unknown region defaults to aws", function()
    local ruleset = {
        parameters = { Region = { type = "string", required = true } },
        rules = {
            { type = "endpoint",
              conditions = {
                  { fn = "aws.partition", argv = { { ref = "Region" } }, assign = "p" },
              },
              endpoint = { url = "https://svc.{Region}.{p#dnsSuffix}" } },
        },
    }
    assert_eq(endpoint.resolve(ruleset, { Region = "us-newregion-1" }).url,
        "https://svc.us-newregion-1.amazonaws.com")
end)

---------------------------------------------------------------------------
-- AWS: aws.parseArn
---------------------------------------------------------------------------

test("fn: aws.parseArn valid", function()
    local ruleset = {
        parameters = { Arn = { type = "string", required = true } },
        rules = {
            { type = "endpoint",
              conditions = {
                  { fn = "aws.parseArn", argv = { { ref = "Arn" } }, assign = "a" },
              },
              endpoint = { url = "https://{a#service}.{a#region}.amazonaws.com" } },
            { type = "error", conditions = {}, error = "invalid arn" },
        },
    }
    assert_eq(endpoint.resolve(ruleset,
        { Arn = "arn:aws:s3:us-west-2:123456789012:bucket/my-bucket" }).url,
        "https://s3.us-west-2.amazonaws.com")
end)

test("fn: aws.parseArn invalid", function()
    local ruleset = {
        parameters = { Arn = { type = "string", required = true } },
        rules = {
            { type = "endpoint",
              conditions = {
                  { fn = "aws.parseArn", argv = { { ref = "Arn" } }, assign = "a" },
              },
              endpoint = { url = "https://ok" } },
            { type = "error", conditions = {}, error = "invalid arn" },
        },
    }
    local _, err = endpoint.resolve(ruleset, { Arn = "not-an-arn" })
    assert_eq(err, "invalid arn")
end)

---------------------------------------------------------------------------
-- AWS: aws.isVirtualHostableS3Bucket
---------------------------------------------------------------------------

test("fn: aws.isVirtualHostableS3Bucket valid", function()
    local ruleset = {
        parameters = { Bucket = { type = "string", required = true } },
        rules = {
            { type = "endpoint",
              conditions = {
                  { fn = "aws.isVirtualHostableS3Bucket", argv = { { ref = "Bucket" }, false } },
              },
              endpoint = { url = "https://{Bucket}.s3.amazonaws.com" } },
            { type = "endpoint", conditions = {},
              endpoint = { url = "https://s3.amazonaws.com/{Bucket}" } },
        },
    }
    assert_eq(endpoint.resolve(ruleset, { Bucket = "my-bucket" }).url,
        "https://my-bucket.s3.amazonaws.com")
end)

test("fn: aws.isVirtualHostableS3Bucket invalid (uppercase)", function()
    local ruleset = {
        parameters = { Bucket = { type = "string", required = true } },
        rules = {
            { type = "endpoint",
              conditions = {
                  { fn = "aws.isVirtualHostableS3Bucket", argv = { { ref = "Bucket" }, false } },
              },
              endpoint = { url = "https://{Bucket}.s3.amazonaws.com" } },
            { type = "endpoint", conditions = {},
              endpoint = { url = "https://s3.amazonaws.com/{Bucket}" } },
        },
    }
    assert_eq(endpoint.resolve(ruleset, { Bucket = "MyBucket" }).url,
        "https://s3.amazonaws.com/MyBucket")
end)

---------------------------------------------------------------------------
-- Endpoint headers
---------------------------------------------------------------------------

test("resolve: endpoint with headers", function()
    local ruleset = {
        parameters = { Region = { type = "string", required = true } },
        rules = {
            { type = "endpoint", conditions = {},
              endpoint = {
                  url = "https://{Region}.example.com",
                  headers = { ["x-amz-region"] = { "{Region}" } },
              } },
        },
    }
    local r = endpoint.resolve(ruleset, { Region = "us-east-1" })
    assert_eq(r.headers["x-amz-region"][1], "us-east-1")
end)

---------------------------------------------------------------------------
-- STS-like integration test
---------------------------------------------------------------------------

test("integration: STS-like ruleset", function()
    local ruleset = {
        parameters = {
            Region = { type = "string", required = true },
            UseFIPS = { type = "boolean", required = true, default = false },
            UseDualStack = { type = "boolean", required = true, default = false },
            Endpoint = { type = "string" },
        },
        rules = {
            -- Custom endpoint override
            {
                type = "tree",
                conditions = {
                    { fn = "isSet", argv = { { ref = "Endpoint" } } },
                },
                rules = {
                    { type = "endpoint", conditions = {},
                      endpoint = { url = "{Endpoint}" } },
                },
            },
            -- Standard resolution
            {
                type = "tree",
                conditions = {
                    { fn = "aws.partition", argv = { { ref = "Region" } }, assign = "partResult" },
                },
                rules = {
                    -- FIPS + DualStack
                    {
                        type = "endpoint",
                        conditions = {
                            { fn = "booleanEquals", argv = { { ref = "UseFIPS" }, true } },
                            { fn = "booleanEquals", argv = { { ref = "UseDualStack" }, true } },
                        },
                        endpoint = {
                            url = "https://sts-fips.{Region}.{partResult#dualStackDnsSuffix}",
                        },
                    },
                    -- FIPS only
                    {
                        type = "endpoint",
                        conditions = {
                            { fn = "booleanEquals", argv = { { ref = "UseFIPS" }, true } },
                        },
                        endpoint = {
                            url = "https://sts-fips.{Region}.{partResult#dnsSuffix}",
                        },
                    },
                    -- DualStack only
                    {
                        type = "endpoint",
                        conditions = {
                            { fn = "booleanEquals", argv = { { ref = "UseDualStack" }, true } },
                        },
                        endpoint = {
                            url = "https://sts.{Region}.{partResult#dualStackDnsSuffix}",
                        },
                    },
                    -- Normal
                    {
                        type = "endpoint",
                        conditions = {},
                        endpoint = {
                            url = "https://sts.{Region}.{partResult#dnsSuffix}",
                        },
                    },
                },
            },
        },
    }

    -- Normal
    local r = endpoint.resolve(ruleset, { Region = "us-east-1" })
    assert_eq(r.url, "https://sts.us-east-1.amazonaws.com")

    -- FIPS
    r = endpoint.resolve(ruleset, { Region = "us-east-1", UseFIPS = true })
    assert_eq(r.url, "https://sts-fips.us-east-1.amazonaws.com")

    -- DualStack
    r = endpoint.resolve(ruleset, { Region = "us-east-1", UseDualStack = true })
    assert_eq(r.url, "https://sts.us-east-1.api.aws")

    -- FIPS + DualStack
    r = endpoint.resolve(ruleset, { Region = "us-east-1", UseFIPS = true, UseDualStack = true })
    assert_eq(r.url, "https://sts-fips.us-east-1.api.aws")

    -- Custom endpoint
    r = endpoint.resolve(ruleset, { Region = "us-east-1", Endpoint = "https://custom.local" })
    assert_eq(r.url, "https://custom.local")

    -- China region
    r = endpoint.resolve(ruleset, { Region = "cn-north-1" })
    assert_eq(r.url, "https://sts.cn-north-1.amazonaws.com.cn")

    -- GovCloud
    r = endpoint.resolve(ruleset, { Region = "us-gov-west-1" })
    assert_eq(r.url, "https://sts.us-gov-west-1.amazonaws.com")
end)

---------------------------------------------------------------------------
-- Rules exhaustion
---------------------------------------------------------------------------

test("resolve: rules exhausted", function()
    local ruleset = {
        parameters = {},
        rules = {
            { type = "endpoint",
              conditions = { { fn = "booleanEquals", argv = { true, false } } },
              endpoint = { url = "https://never" } },
        },
    }
    local result, err = endpoint.resolve(ruleset, {})
    assert_nil(result)
    assert_truthy(err:find("exhausted"), err)
end)

---------------------------------------------------------------------------
-- Summary
---------------------------------------------------------------------------

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
