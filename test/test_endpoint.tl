local assert = require("luassert") as any
-- Test: runtime/endpoint.lua

local endpoint = require("smithy.endpoint")

describe("endpoint", function()

---------------------------------------------------------------------------
-- Basic resolve: simple endpoint rule
---------------------------------------------------------------------------

it("resolve: simple endpoint", function()
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
    assert.is_nil(err)
    assert.are.equal("https://us-east-1.example.com", (result as {string:any}).url)
end)

it("resolve: missing required param", function()
    local ruleset = {
        parameters = {
            Region = { type = "string", required = true },
        },
        rules = {},
    }
    local result, err = endpoint.resolve(ruleset, {})
    assert.is_nil(result)
    assert.is_truthy((err as string):find("required"))
end)

it("resolve: default param value", function()
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
    assert.are.equal("https://us-west-2.example.com", (result as {string:any}).url)
end)

---------------------------------------------------------------------------
-- Error rules
---------------------------------------------------------------------------

it("resolve: error rule", function()
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
    assert.is_nil(result)
    assert.are.equal("this service is not available", err)
end)

it("resolve: error rule with template", function()
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
    assert.are.equal("no endpoint for mars-1", err)
end)

---------------------------------------------------------------------------
-- Tree rules
---------------------------------------------------------------------------

it("resolve: tree rule", function()
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
    assert.are.equal("https://us-east-1.fips.example.com", (r1 as {string:any}).url)

    local r2 = endpoint.resolve(ruleset, { Region = "us-east-1", UseFIPS = false })
    assert.are.equal("https://us-east-1.example.com", (r2 as {string:any}).url)
end)

---------------------------------------------------------------------------
-- Condition assign
---------------------------------------------------------------------------

it("resolve: condition assign", function()
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
    assert.are.equal("https://my.host:8443/custom", (r1 as {string:any}).url)

    local r2 = endpoint.resolve(ruleset, {})
    assert.are.equal("https://default.example.com", (r2 as {string:any}).url)
end)

---------------------------------------------------------------------------
-- Standard library: isSet
---------------------------------------------------------------------------

it("fn: isSet true", function()
    local ruleset = {
        parameters = { Foo = { type = "string" } },
        rules = {
            { type = "endpoint", conditions = { { fn = "isSet", argv = { { ref = "Foo" } } } },
              endpoint = { url = "https://yes.com" } },
            { type = "endpoint", conditions = {}, endpoint = { url = "https://no.com" } },
        },
    }
    assert.are.equal("https://yes.com", (endpoint.resolve(ruleset, { Foo = "bar" }) as {string:any}).url)
    assert.are.equal("https://no.com", (endpoint.resolve(ruleset, {}) as {string:any}).url)
end)

---------------------------------------------------------------------------
-- Standard library: stringEquals, booleanEquals, not
---------------------------------------------------------------------------

it("fn: stringEquals", function()
    local ruleset = {
        parameters = { Region = { type = "string", required = true } },
        rules = {
            { type = "endpoint",
              conditions = { { fn = "stringEquals", argv = { { ref = "Region" }, "us-east-1" } } },
              endpoint = { url = "https://special.com" } },
            { type = "endpoint", conditions = {}, endpoint = { url = "https://default.com" } },
        },
    }
    assert.are.equal("https://special.com", (endpoint.resolve(ruleset, { Region = "us-east-1" }) as {string:any}).url)
    assert.are.equal("https://default.com", (endpoint.resolve(ruleset, { Region = "eu-west-1" }) as {string:any}).url)
end)

it("fn: not", function()
    local ruleset = {
        parameters = { UseFIPS = { type = "boolean", required = true, default = false } },
        rules = {
            { type = "endpoint",
              conditions = { { fn = "not", argv = { { ref = "UseFIPS" } } } },
              endpoint = { url = "https://normal.com" } },
            { type = "endpoint", conditions = {}, endpoint = { url = "https://fips.com" } },
        },
    }
    assert.are.equal("https://normal.com", (endpoint.resolve(ruleset, { UseFIPS = false }) as {string:any}).url)
    assert.are.equal("https://fips.com", (endpoint.resolve(ruleset, { UseFIPS = true }) as {string:any}).url)
end)

---------------------------------------------------------------------------
-- Standard library: getAttr
---------------------------------------------------------------------------

it("fn: getAttr nested", function()
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
    assert.are.equal("http://custom", (endpoint.resolve(ruleset, { Endpoint = "http://foo.com" }) as {string:any}).url)
end)

---------------------------------------------------------------------------
-- Standard library: isValidHostLabel
---------------------------------------------------------------------------

it("fn: isValidHostLabel", function()
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
    assert.are.equal("https://my-bucket.s3.amazonaws.com",
        (endpoint.resolve(ruleset, { Bucket = "my-bucket" }) as {string:any}).url)
    assert.are.equal("https://s3.amazonaws.com/INVALID..bucket",
        (endpoint.resolve(ruleset, { Bucket = "INVALID..bucket" }) as {string:any}).url)
end)

---------------------------------------------------------------------------
-- Standard library: parseURL
---------------------------------------------------------------------------

it("fn: parseURL basic", function()
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
    assert.are.equal("https://example.com:8443/base/svc", (r as {string:any}).url)
end)

it("fn: parseURL rejects query", function()
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
    assert.are.equal("bad url", err)
end)

it("fn: parseURL isIp", function()
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
    assert.are.equal("https://ip-endpoint", (endpoint.resolve(ruleset, { Endpoint = "https://127.0.0.1" }) as {string:any}).url)
    assert.are.equal("https://host-endpoint", (endpoint.resolve(ruleset, { Endpoint = "https://example.com" }) as {string:any}).url)
end)

---------------------------------------------------------------------------
-- Standard library: substring
---------------------------------------------------------------------------

it("fn: substring forward", function()
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
    assert.are.equal("https://abcd.example.com", (endpoint.resolve(ruleset, { Input = "abcdefgh" }) as {string:any}).url)
end)

it("fn: substring reverse", function()
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
    assert.are.equal("https://efgh.example.com", (endpoint.resolve(ruleset, { Input = "abcdefgh" }) as {string:any}).url)
end)

it("fn: substring too short returns nil", function()
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
    assert.are.equal("too short", err)
end)

---------------------------------------------------------------------------
-- Standard library: uriEncode
---------------------------------------------------------------------------

it("fn: uriEncode", function()
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
    assert.are.equal("https://s3.amazonaws.com/hello%20world%2Ffile",
        (endpoint.resolve(ruleset, { Key = "hello world/file" }) as {string:any}).url)
end)

---------------------------------------------------------------------------
-- Standard library: split
---------------------------------------------------------------------------

it("fn: split unlimited", function()
    local ruleset = {
        parameters = { Name = { type = "string", required = true } },
        rules = {
            { type = "endpoint",
              conditions = {
                  { fn = "split", argv = { { ref = "Name" }, "--", 0 }, assign = "parts" },
              },
              endpoint = { url = "https://{parts#[0]}.example.com" } },
        },
    }
    assert.are.equal("https://a.example.com", (endpoint.resolve(ruleset, { Name = "a--b--c" }) as {string:any}).url)
end)

it("fn: split with limit", function()
    local ruleset = {
        parameters = { Name = { type = "string", required = true } },
        rules = {
            { type = "endpoint",
              conditions = {
                  { fn = "split", argv = { { ref = "Name" }, "--", 2 }, assign = "parts" },
              },
              endpoint = { url = "https://{parts#[1]}.example.com" } },
        },
    }
    assert.are.equal("https://b--c.example.com", (endpoint.resolve(ruleset, { Name = "a--b--c" }) as {string:any}).url)
end)

---------------------------------------------------------------------------
-- Standard library: coalesce
---------------------------------------------------------------------------

it("fn: coalesce picks first set", function()
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
    assert.are.equal("https://override.example.com", (endpoint.resolve(ruleset, { Custom = "override" }) as {string:any}).url)
    assert.are.equal("https://fallback.example.com", (endpoint.resolve(ruleset, {}) as {string:any}).url)
end)

---------------------------------------------------------------------------
-- Standard library: ite
---------------------------------------------------------------------------

it("fn: ite", function()
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
    assert.are.equal("https://svc-fips.example.com", (endpoint.resolve(ruleset, { UseFIPS = true }) as {string:any}).url)
    assert.are.equal("https://svc.example.com", (endpoint.resolve(ruleset, { UseFIPS = false }) as {string:any}).url)
end)

---------------------------------------------------------------------------
-- AWS: aws.partition
---------------------------------------------------------------------------

it("fn: aws.partition us-east-1", function()
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
    assert.are.equal("https://svc.us-east-1.amazonaws.com",
        (endpoint.resolve(ruleset, { Region = "us-east-1" }) as {string:any}).url)
end)

it("fn: aws.partition cn region", function()
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
    assert.are.equal("https://svc.cn-north-1.amazonaws.com.cn",
        (endpoint.resolve(ruleset, { Region = "cn-north-1" }) as {string:any}).url)
end)

it("fn: aws.partition gov region", function()
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
    assert.are.equal("https://svc.us-gov-west-1.amazonaws.com",
        (endpoint.resolve(ruleset, { Region = "us-gov-west-1" }) as {string:any}).url)
end)

it("fn: aws.partition unknown region defaults to aws", function()
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
    assert.are.equal("https://svc.us-newregion-1.amazonaws.com",
        (endpoint.resolve(ruleset, { Region = "us-newregion-1" }) as {string:any}).url)
end)

---------------------------------------------------------------------------
-- AWS: aws.parseArn
---------------------------------------------------------------------------

it("fn: aws.parseArn valid", function()
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
    assert.are.equal("https://s3.us-west-2.amazonaws.com",
        (endpoint.resolve(ruleset, { Arn = "arn:aws:s3:us-west-2:123456789012:bucket/my-bucket" }) as {string:any}).url)
end)

it("fn: aws.parseArn invalid", function()
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
    assert.are.equal("invalid arn", err)
end)

---------------------------------------------------------------------------
-- AWS: aws.isVirtualHostableS3Bucket
---------------------------------------------------------------------------

it("fn: aws.isVirtualHostableS3Bucket valid", function()
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
    assert.are.equal("https://my-bucket.s3.amazonaws.com",
        (endpoint.resolve(ruleset, { Bucket = "my-bucket" }) as {string:any}).url)
end)

it("fn: aws.isVirtualHostableS3Bucket invalid (uppercase)", function()
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
    assert.are.equal("https://s3.amazonaws.com/MyBucket",
        (endpoint.resolve(ruleset, { Bucket = "MyBucket" }) as {string:any}).url)
end)

---------------------------------------------------------------------------
-- Endpoint headers
---------------------------------------------------------------------------

it("resolve: endpoint with headers", function()
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
    local hdrs = (r as {string:any}).headers as {string:any}
    local vals = hdrs["x-amz-region"] as {string}
    assert.are.equal("us-east-1", vals[1])
end)

---------------------------------------------------------------------------
-- STS-like integration test
---------------------------------------------------------------------------

it("integration: STS-like ruleset", function()
    local ruleset = {
        parameters = {
            Region = { type = "string", required = true },
            UseFIPS = { type = "boolean", required = true, default = false },
            UseDualStack = { type = "boolean", required = true, default = false },
            Endpoint = { type = "string" },
        },
        rules = {
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
            {
                type = "tree",
                conditions = {
                    { fn = "aws.partition", argv = { { ref = "Region" } }, assign = "partResult" },
                },
                rules = {
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
                    {
                        type = "endpoint",
                        conditions = {
                            { fn = "booleanEquals", argv = { { ref = "UseFIPS" }, true } },
                        },
                        endpoint = {
                            url = "https://sts-fips.{Region}.{partResult#dnsSuffix}",
                        },
                    },
                    {
                        type = "endpoint",
                        conditions = {
                            { fn = "booleanEquals", argv = { { ref = "UseDualStack" }, true } },
                        },
                        endpoint = {
                            url = "https://sts.{Region}.{partResult#dualStackDnsSuffix}",
                        },
                    },
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

    local r: any

    r = endpoint.resolve(ruleset, { Region = "us-east-1" })
    assert.are.equal("https://sts.us-east-1.amazonaws.com", (r as {string:any}).url)

    r = endpoint.resolve(ruleset, { Region = "us-east-1", UseFIPS = true })
    assert.are.equal("https://sts-fips.us-east-1.amazonaws.com", (r as {string:any}).url)

    r = endpoint.resolve(ruleset, { Region = "us-east-1", UseDualStack = true })
    assert.are.equal("https://sts.us-east-1.api.aws", (r as {string:any}).url)

    r = endpoint.resolve(ruleset, { Region = "us-east-1", UseFIPS = true, UseDualStack = true })
    assert.are.equal("https://sts-fips.us-east-1.api.aws", (r as {string:any}).url)

    r = endpoint.resolve(ruleset, { Region = "us-east-1", Endpoint = "https://custom.local" })
    assert.are.equal("https://custom.local", (r as {string:any}).url)

    r = endpoint.resolve(ruleset, { Region = "cn-north-1" })
    assert.are.equal("https://sts.cn-north-1.amazonaws.com.cn", (r as {string:any}).url)

    r = endpoint.resolve(ruleset, { Region = "us-gov-west-1" })
    assert.are.equal("https://sts.us-gov-west-1.amazonaws.com", (r as {string:any}).url)
end)

---------------------------------------------------------------------------
-- Rules exhaustion
---------------------------------------------------------------------------

it("resolve: rules exhausted", function()
    local ruleset = {
        parameters = {},
        rules = {
            { type = "endpoint",
              conditions = { { fn = "booleanEquals", argv = { true, false } } },
              endpoint = { url = "https://never" } },
        },
    }
    local result, err = endpoint.resolve(ruleset, {})
    assert.is_nil(result)
    assert.is_truthy((err as string):find("exhausted"))
end)

end)
