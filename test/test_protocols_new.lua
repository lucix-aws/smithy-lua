-- Tests for all new protocols: restXml, awsQuery, ec2Query, rpcv2Cbor

package.path = "runtime/?.lua;" .. package.path

local http = require("http")
local schema_mod = require("schema")
local stype = schema_mod.type
local strait = schema_mod.trait

local passed, failed = 0, 0

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("  PASS: " .. name)
    else
        failed = failed + 1
        print("  FAIL: " .. name .. " — " .. tostring(err))
    end
end

local function assert_eq(a, b, msg)
    if a ~= b then
        error((msg or "") .. " expected: " .. tostring(b) .. ", got: " .. tostring(a), 2)
    end
end

local function assert_contains(s, sub, msg)
    if not s:find(sub, 1, true) then
        error((msg or "") .. " expected to contain: " .. sub .. ", got: " .. s, 2)
    end
end

local function mock_response(status, body, headers)
    return {
        status_code = status,
        headers = headers or {},
        body = http.string_reader(body or ""),
    }
end

local function read_body(request)
    return http.read_all(request.body)
end

-- ============================================================
-- restXml protocol tests
-- ============================================================

print("\n--- restXml protocol ---")

local restxml = require("protocol.restxml")
local restxml_proto = restxml.new()

test("restxml serialize: basic structure body", function()
    local op = {
        name = "PutObject",
        http_method = "PUT",
        http_path = "/{Bucket}/{Key+}",
        input_schema = {
            type = stype.STRUCTURE,
            members = {
                Bucket = { type = stype.STRING, traits = { [strait.HTTP_LABEL] = true } },
                Key = { type = stype.STRING, traits = { [strait.HTTP_LABEL] = true } },
                ContentType = { type = stype.STRING, traits = { [strait.HTTP_HEADER] = "Content-Type" } },
                Body = { type = stype.BLOB, traits = { [strait.HTTP_PAYLOAD] = true } },
            },
        },
    }
    local req, err = restxml_proto:serialize({
        Bucket = "my-bucket",
        Key = "path/to/file.txt",
        ContentType = "text/plain",
        Body = "hello",
    }, op)
    assert(not err, tostring(err and err.message))
    assert_eq(req.method, "PUT")
    assert_contains(req.url, "/my-bucket/path/to/file.txt")
    assert_eq(req.headers["Content-Type"], "text/plain")
    assert_eq(read_body(req), "hello")
end)

test("restxml serialize: xml body members", function()
    local op = {
        name = "CreateBucket",
        http_method = "PUT",
        http_path = "/{Bucket}",
        input_schema = {
            type = stype.STRUCTURE,
            id = "CreateBucketRequest",
            members = {
                Bucket = { type = stype.STRING, traits = { [strait.HTTP_LABEL] = true } },
                LocationConstraint = { type = stype.STRING },
            },
        },
    }
    local req = restxml_proto:serialize({
        Bucket = "test",
        LocationConstraint = "us-west-2",
    }, op)
    assert_eq(req.headers["Content-Type"], "application/xml")
    local body = read_body(req)
    assert_contains(body, "<LocationConstraint>us-west-2</LocationConstraint>")
end)

test("restxml serialize: no body when no body members", function()
    local op = {
        name = "DeleteBucket",
        http_method = "DELETE",
        http_path = "/{Bucket}",
        input_schema = {
            type = stype.STRUCTURE,
            members = {
                Bucket = { type = stype.STRING, traits = { [strait.HTTP_LABEL] = true } },
            },
        },
    }
    local req = restxml_proto:serialize({ Bucket = "test" }, op)
    assert_eq(read_body(req), "")
    assert_eq(req.headers["Content-Type"], nil)
end)

test("restxml deserialize: success with xml body", function()
    local op = {
        name = "ListBuckets",
        output_schema = {
            type = stype.STRUCTURE,
            members = {
                Owner = {
                    type = stype.STRUCTURE,
                    members = {
                        DisplayName = { type = stype.STRING },
                        ID = { type = stype.STRING },
                    },
                },
            },
        },
    }
    local resp = mock_response(200,
        '<ListBucketsResult><Owner><DisplayName>test</DisplayName><ID>abc</ID></Owner></ListBucketsResult>')
    local result, err = restxml_proto:deserialize(resp, op)
    assert(not err, tostring(err and err.message))
    assert_eq(result.Owner.DisplayName, "test")
    assert_eq(result.Owner.ID, "abc")
end)

test("restxml deserialize: error (wrapped)", function()
    local op = { name = "GetObject", output_schema = { type = stype.STRUCTURE, members = {} } }
    local resp = mock_response(404,
        '<ErrorResponse><Error><Code>NoSuchKey</Code><Message>The specified key does not exist.</Message></Error></ErrorResponse>')
    local result, err = restxml_proto:deserialize(resp, op)
    assert(err)
    assert_eq(err.code, "NoSuchKey")
    assert_contains(err.message, "does not exist")
end)

test("restxml deserialize: error (no wrapping)", function()
    local proto = restxml.new({ no_error_wrapping = true })
    local op = { name = "GetObject", output_schema = { type = stype.STRUCTURE, members = {} } }
    local resp = mock_response(404,
        '<Error><Code>NoSuchKey</Code><Message>Not found</Message></Error>')
    local result, err = proto:deserialize(resp, op)
    assert(err)
    assert_eq(err.code, "NoSuchKey")
end)

test("restxml deserialize: header bindings", function()
    local op = {
        name = "HeadObject",
        output_schema = {
            type = stype.STRUCTURE,
            members = {
                ContentLength = { type = stype.LONG, traits = { [strait.HTTP_HEADER] = "Content-Length" } },
                ContentType = { type = stype.STRING, traits = { [strait.HTTP_HEADER] = "Content-Type" } },
            },
        },
    }
    local resp = mock_response(200, "", {
        ["Content-Length"] = "1234",
        ["Content-Type"] = "application/xml",
    })
    local result, err = restxml_proto:deserialize(resp, op)
    assert(not err)
    assert_eq(result.ContentLength, 1234)
    assert_eq(result.ContentType, "application/xml")
end)

-- ============================================================
-- awsQuery protocol tests
-- ============================================================

print("\n--- awsQuery protocol ---")

local awsquery = require("protocol.awsquery")
local query_proto = awsquery.new({ version = "2011-06-15" })

test("awsquery serialize: basic", function()
    local op = {
        name = "GetCallerIdentity",
        input_schema = { type = stype.STRUCTURE, members = {} },
    }
    local req, err = query_proto:serialize({}, op)
    assert(not err)
    assert_eq(req.method, "POST")
    assert_eq(req.url, "/")
    assert_eq(req.headers["Content-Type"], "application/x-www-form-urlencoded")
    local body = read_body(req)
    assert_contains(body, "Action=GetCallerIdentity")
    assert_contains(body, "Version=2011-06-15")
end)

test("awsquery serialize: simple members", function()
    local op = {
        name = "CreateQueue",
        input_schema = {
            type = stype.STRUCTURE,
            members = {
                QueueName = { type = stype.STRING },
                DelaySeconds = { type = stype.INTEGER },
            },
        },
    }
    local req = query_proto:serialize({ QueueName = "test", DelaySeconds = 5 }, op)
    local body = read_body(req)
    assert_contains(body, "QueueName=test")
    assert_contains(body, "DelaySeconds=5")
end)

test("awsquery serialize: list (non-flattened)", function()
    local op = {
        name = "TestOp",
        input_schema = {
            type = stype.STRUCTURE,
            members = {
                Items = {
                    type = stype.LIST,
                    member = { type = stype.STRING },
                },
            },
        },
    }
    local req = query_proto:serialize({ Items = { "a", "b" } }, op)
    local body = read_body(req)
    assert_contains(body, "Items.member.1=a")
    assert_contains(body, "Items.member.2=b")
end)

test("awsquery serialize: list (flattened)", function()
    local op = {
        name = "TestOp",
        input_schema = {
            type = stype.STRUCTURE,
            members = {
                Items = {
                    type = stype.LIST,
                    member = { type = stype.STRING },
                    traits = { [strait.XML_FLATTENED] = true },
                },
            },
        },
    }
    local req = query_proto:serialize({ Items = { "a", "b" } }, op)
    local body = read_body(req)
    assert_contains(body, "Items.1=a")
    assert_contains(body, "Items.2=b")
    assert(not body:find("member"), "should not have .member. segment")
end)

test("awsquery serialize: map (non-flattened)", function()
    local op = {
        name = "TestOp",
        input_schema = {
            type = stype.STRUCTURE,
            members = {
                Tags = {
                    type = stype.MAP,
                    key = { type = stype.STRING },
                    value = { type = stype.STRING },
                },
            },
        },
    }
    local req = query_proto:serialize({ Tags = { foo = "bar" } }, op)
    local body = read_body(req)
    assert_contains(body, "Tags.entry.1.key=foo")
    assert_contains(body, "Tags.entry.1.value=bar")
end)

test("awsquery serialize: nested structure", function()
    local op = {
        name = "TestOp",
        input_schema = {
            type = stype.STRUCTURE,
            members = {
                Config = {
                    type = stype.STRUCTURE,
                    members = {
                        Name = { type = stype.STRING },
                    },
                },
            },
        },
    }
    local req = query_proto:serialize({ Config = { Name = "test" } }, op)
    local body = read_body(req)
    assert_contains(body, "Config.Name=test")
end)

test("awsquery serialize: xmlName on member", function()
    local op = {
        name = "TestOp",
        input_schema = {
            type = stype.STRUCTURE,
            members = {
                Foo = { type = stype.STRING, traits = { [strait.XML_NAME] = "Custom" } },
            },
        },
    }
    local req = query_proto:serialize({ Foo = "bar" }, op)
    local body = read_body(req)
    assert_contains(body, "Custom=bar")
end)

test("awsquery serialize: boolean", function()
    local op = {
        name = "TestOp",
        input_schema = {
            type = stype.STRUCTURE,
            members = {
                Flag = { type = stype.BOOLEAN },
            },
        },
    }
    local req = query_proto:serialize({ Flag = true }, op)
    local body = read_body(req)
    assert_contains(body, "Flag=true")
end)

test("awsquery deserialize: success", function()
    local op = {
        name = "GetCallerIdentity",
        output_schema = {
            type = stype.STRUCTURE,
            members = {
                Account = { type = stype.STRING },
                Arn = { type = stype.STRING },
            },
        },
    }
    local resp = mock_response(200,
        '<GetCallerIdentityResponse><GetCallerIdentityResult><Account>123456789012</Account><Arn>arn:aws:iam::123456789012:root</Arn></GetCallerIdentityResult></GetCallerIdentityResponse>')
    local result, err = query_proto:deserialize(resp, op)
    assert(not err, tostring(err and err.message))
    assert_eq(result.Account, "123456789012")
end)

test("awsquery deserialize: error", function()
    local op = {
        name = "GetCallerIdentity",
        output_schema = { type = stype.STRUCTURE, members = {} },
    }
    local resp = mock_response(403,
        '<ErrorResponse><Error><Type>Sender</Type><Code>AccessDenied</Code><Message>Access denied</Message></Error><RequestId>abc</RequestId></ErrorResponse>')
    local result, err = query_proto:deserialize(resp, op)
    assert(err)
    assert_eq(err.code, "AccessDenied")
    assert_eq(err.message, "Access denied")
end)

test("awsquery deserialize: empty body", function()
    local op = {
        name = "DeleteQueue",
        output_schema = { type = stype.STRUCTURE, members = {} },
    }
    local resp = mock_response(200, "")
    local result, err = query_proto:deserialize(resp, op)
    assert(not err)
    assert(type(result) == "table")
end)

-- ============================================================
-- ec2Query protocol tests
-- ============================================================

print("\n--- ec2Query protocol ---")

local ec2query = require("protocol.ec2query")
local ec2_proto = ec2query.new({ version = "2016-11-15" })

test("ec2query serialize: basic", function()
    local op = {
        name = "DescribeInstances",
        input_schema = { type = stype.STRUCTURE, members = {} },
    }
    local req = ec2_proto:serialize({}, op)
    local body = read_body(req)
    assert_contains(body, "Action=DescribeInstances")
    assert_contains(body, "Version=2016-11-15")
end)

test("ec2query serialize: capitalizes member names", function()
    local op = {
        name = "TestOp",
        input_schema = {
            type = stype.STRUCTURE,
            members = {
                instanceId = { type = stype.STRING },
            },
        },
    }
    local req = ec2_proto:serialize({ instanceId = "i-123" }, op)
    local body = read_body(req)
    assert_contains(body, "InstanceId=i-123")
end)

test("ec2query serialize: ec2QueryName takes precedence", function()
    local op = {
        name = "TestOp",
        input_schema = {
            type = stype.STRUCTURE,
            members = {
                bar = {
                    type = stype.STRING,
                    traits = {
                        [strait.EC2_QUERY_NAME] = "Foo",
                        [strait.XML_NAME] = "IgnoreMe",
                    },
                },
            },
        },
    }
    local req = ec2_proto:serialize({ bar = "baz" }, op)
    local body = read_body(req)
    assert_contains(body, "Foo=baz")
    assert(not body:find("IgnoreMe"), "should not use xmlName when ec2QueryName present")
    assert(not body:find("Bar="), "should not use capitalized member name")
end)

test("ec2query serialize: xmlName capitalized", function()
    local op = {
        name = "TestOp",
        input_schema = {
            type = stype.STRUCTURE,
            members = {
                foo = {
                    type = stype.STRING,
                    traits = { [strait.XML_NAME] = "custom" },
                },
            },
        },
    }
    local req = ec2_proto:serialize({ foo = "bar" }, op)
    local body = read_body(req)
    assert_contains(body, "Custom=bar")
end)

test("ec2query serialize: lists always flattened", function()
    local op = {
        name = "TestOp",
        input_schema = {
            type = stype.STRUCTURE,
            members = {
                items = {
                    type = stype.LIST,
                    member = { type = stype.STRING },
                    -- Note: no xmlFlattened trait, but ec2 always flattens
                },
            },
        },
    }
    local req = ec2_proto:serialize({ items = { "a", "b" } }, op)
    local body = read_body(req)
    assert_contains(body, "Items.1=a")
    assert_contains(body, "Items.2=b")
    assert(not body:find("member"), "ec2 should not have .member. segment")
end)

test("ec2query deserialize: success (no Result wrapper)", function()
    local op = {
        name = "DescribeInstances",
        output_schema = {
            type = stype.STRUCTURE,
            members = {
                NextToken = { type = stype.STRING, traits = { [strait.XML_NAME] = "nextToken" } },
            },
        },
    }
    local resp = mock_response(200,
        '<DescribeInstancesResponse><nextToken>abc123</nextToken></DescribeInstancesResponse>')
    local result, err = ec2_proto:deserialize(resp, op)
    assert(not err, tostring(err and err.message))
    assert_eq(result.NextToken, "abc123")
end)

test("ec2query deserialize: error", function()
    local op = {
        name = "DescribeInstances",
        output_schema = { type = stype.STRUCTURE, members = {} },
    }
    local resp = mock_response(400,
        '<Response><Errors><Error><Code>InvalidParameterValue</Code><Message>Bad param</Message></Error></Errors><RequestID>abc</RequestID></Response>')
    local result, err = ec2_proto:deserialize(resp, op)
    assert(err)
    assert_eq(err.code, "InvalidParameterValue")
    assert_eq(err.message, "Bad param")
end)

-- ============================================================
-- rpcv2Cbor protocol tests
-- ============================================================

print("\n--- rpcv2Cbor protocol ---")

local rpcv2cbor = require("protocol.rpcv2cbor")
local cbor_proto = rpcv2cbor.new({ service_name = "TestService" })

test("rpcv2cbor serialize: basic", function()
    local op = {
        name = "DoThing",
        input_schema = {
            type = stype.STRUCTURE,
            members = {
                Name = { type = stype.STRING },
            },
        },
    }
    local req, err = cbor_proto:serialize({ Name = "test" }, op)
    assert(not err)
    assert_eq(req.method, "POST")
    assert_eq(req.url, "/service/TestService/operation/DoThing")
    assert_eq(req.headers["Smithy-Protocol"], "rpc-v2-cbor")
    assert_eq(req.headers["Accept"], "application/cbor")
    assert_eq(req.headers["Content-Type"], "application/cbor")
    local body = read_body(req)
    assert(#body > 0, "should have CBOR body")
end)

test("rpcv2cbor serialize: empty input = no Content-Type", function()
    local op = {
        name = "DoThing",
        input_schema = { type = stype.STRUCTURE, members = {} },
    }
    local req = cbor_proto:serialize({}, op)
    assert_eq(req.headers["Content-Type"], nil)
    assert_eq(read_body(req), "")
end)

test("rpcv2cbor serialize: nil members = no Content-Type", function()
    local op = {
        name = "DoThing",
        input_schema = {
            type = stype.STRUCTURE,
            members = {
                Name = { type = stype.STRING },
            },
        },
    }
    local req = cbor_proto:serialize({}, op)
    assert_eq(req.headers["Content-Type"], nil)
    assert_eq(read_body(req), "")
end)

test("rpcv2cbor deserialize: success", function()
    -- First serialize a known value, then deserialize it
    local cbor_codec = require("codec.cbor")
    local codec = cbor_codec.new()
    local output_schema = {
        type = stype.STRUCTURE,
        members = {
            Result = { type = stype.STRING },
            Count = { type = stype.INTEGER },
        },
    }
    local body_bytes = codec:serialize({ Result = "ok", Count = 42 }, output_schema)
    local resp = mock_response(200, body_bytes, {
        ["Smithy-Protocol"] = "rpc-v2-cbor",
        ["Content-Type"] = "application/cbor",
    })
    local op = { name = "DoThing", output_schema = output_schema }
    local result, err = cbor_proto:deserialize(resp, op)
    assert(not err, tostring(err and err.message))
    assert_eq(result.Result, "ok")
    assert_eq(result.Count, 42)
end)

test("rpcv2cbor deserialize: empty body", function()
    local resp = mock_response(200, "", {
        ["Smithy-Protocol"] = "rpc-v2-cbor",
    })
    local op = { name = "DoThing", output_schema = { type = stype.STRUCTURE, members = {} } }
    local result, err = cbor_proto:deserialize(resp, op)
    assert(not err)
    assert(type(result) == "table")
end)

test("rpcv2cbor deserialize: error", function()
    local cbor_codec = require("codec.cbor")
    local codec = cbor_codec.new()
    local error_schema = { type = stype.STRUCTURE, members = {
        ["__type"] = { type = stype.STRING },
        message = { type = stype.STRING },
    }}
    local body_bytes = codec:serialize({
        ["__type"] = "com.example#ValidationException",
        message = "Invalid input",
    }, error_schema)
    local resp = mock_response(400, body_bytes, {
        ["Smithy-Protocol"] = "rpc-v2-cbor",
        ["Content-Type"] = "application/cbor",
    })
    local op = { name = "DoThing", output_schema = { type = stype.STRUCTURE, members = {} } }
    local result, err = cbor_proto:deserialize(resp, op)
    assert(err)
    assert_eq(err.code, "ValidationException")
    assert_eq(err.message, "Invalid input")
end)

test("rpcv2cbor deserialize: protocol mismatch", function()
    local resp = mock_response(200, "", {
        ["Smithy-Protocol"] = "wrong-protocol",
    })
    local op = { name = "DoThing", output_schema = { type = stype.STRUCTURE, members = {} } }
    local result, err = cbor_proto:deserialize(resp, op)
    assert(err)
    assert_eq(err.code, "ProtocolMismatch")
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
