-- Test: runtime/protocol/restjson.lua — restJson1 protocol with HTTP bindings
-- Run: luajit test/test_protocol_restjson.lua

package.path = "runtime/?.lua;runtime/?/init.lua;" .. package.path

local restjson = require("smithy.protocol.restjson")
local http = require("smithy.http")
local stype = require("smithy.schema").type
local strait = require("smithy.schema").trait

local pass_count = 0

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        pass_count = pass_count + 1
        print("PASS: " .. name)
    else
        print("FAIL: " .. name .. "\n  " .. tostring(err))
        os.exit(1)
    end
end

local function assert_eq(a, b, msg)
    if a ~= b then
        error((msg or "assert_eq") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2)
    end
end

local function assert_contains(s, sub, msg)
    if not s:find(sub, 1, true) then
        error((msg or "assert_contains") .. ": " .. tostring(s) .. " does not contain " .. tostring(sub), 2)
    end
end

local protocol = restjson.new()

-- ============================================================
-- Serialize tests
-- ============================================================

-- Simple body-only members (no HTTP bindings)
test("serialize: body-only members as JSON", function()
    local op = {
        name = "CreateThing",
        http_method = "POST",
        http_path = "/things",
        input_schema = {
            type = stype.STRUCTURE,
            members = {
                Name = { type = stype.STRING },
                Count = { type = stype.INTEGER },
            },
        },
    }
    local req, err = protocol:serialize({ Name = "foo", Count = 5 }, op)
    assert(not err, tostring(err and err.message))
    assert_eq(req.method, "POST")
    assert_eq(req.url, "/things")
    assert_eq(req.headers["Content-Type"], "application/json")
    local body = http.read_all(req.body)
    assert_eq(body, '{"Count":5,"Name":"foo"}')
end)

-- Empty body: no Content-Type
test("serialize: no body members omits Content-Type", function()
    local op = {
        name = "DeleteThing",
        http_method = "DELETE",
        http_path = "/things/{Id}",
        input_schema = {
            type = stype.STRUCTURE,
            members = {
                Id = { type = stype.STRING, traits = { [strait.HTTP_LABEL] = true } },
            },
        },
    }
    local req, err = protocol:serialize({ Id = "abc" }, op)
    assert(not err)
    assert_eq(req.url, "/things/abc")
    assert_eq(req.headers["Content-Type"], nil)
    assert_eq(http.read_all(req.body), "")
end)

-- URI labels
test("serialize: URI label expansion", function()
    local op = {
        name = "GetItem",
        http_method = "GET",
        http_path = "/tables/{TableName}/items/{ItemId}",
        input_schema = {
            type = stype.STRUCTURE,
            members = {
                TableName = { type = stype.STRING, traits = { [strait.HTTP_LABEL] = true } },
                ItemId = { type = stype.STRING, traits = { [strait.HTTP_LABEL] = true } },
            },
        },
    }
    local req, err = protocol:serialize({ TableName = "users", ItemId = "123" }, op)
    assert(not err)
    assert_eq(req.url, "/tables/users/items/123")
end)

-- URI label encoding
test("serialize: URI label percent-encodes special chars", function()
    local op = {
        name = "GetItem",
        http_method = "GET",
        http_path = "/items/{Id}",
        input_schema = {
            type = stype.STRUCTURE,
            members = {
                Id = { type = stype.STRING, traits = { [strait.HTTP_LABEL] = true } },
            },
        },
    }
    local req, err = protocol:serialize({ Id = "hello world/foo" }, op)
    assert(not err)
    assert_eq(req.url, "/items/hello%20world%2Ffoo")
end)

-- Greedy label
test("serialize: greedy label preserves slashes", function()
    local op = {
        name = "GetObject",
        http_method = "GET",
        http_path = "/buckets/{Bucket}/{Key+}",
        input_schema = {
            type = stype.STRUCTURE,
            members = {
                Bucket = { type = stype.STRING, traits = { [strait.HTTP_LABEL] = true } },
                Key = { type = stype.STRING, traits = { [strait.HTTP_LABEL] = true } },
            },
        },
    }
    local req, err = protocol:serialize({ Bucket = "my-bucket", Key = "path/to/file.txt" }, op)
    assert(not err)
    assert_eq(req.url, "/buckets/my-bucket/path/to/file.txt")
end)

-- Query string params
test("serialize: query string params", function()
    local op = {
        name = "ListItems",
        http_method = "GET",
        http_path = "/items",
        input_schema = {
            type = stype.STRUCTURE,
            members = {
                MaxResults = { type = stype.INTEGER, traits = { [strait.HTTP_QUERY] = "maxResults" } },
                NextToken = { type = stype.STRING, traits = { [strait.HTTP_QUERY] = "nextToken" } },
            },
        },
    }
    local req, err = protocol:serialize({ MaxResults = 10, NextToken = "abc" }, op)
    assert(not err)
    assert_eq(req.url, "/items?maxResults=10&nextToken=abc")
end)

-- Query string: nil values omitted
test("serialize: nil query params omitted", function()
    local op = {
        name = "ListItems",
        http_method = "GET",
        http_path = "/items",
        input_schema = {
            type = stype.STRUCTURE,
            members = {
                MaxResults = { type = stype.INTEGER, traits = { [strait.HTTP_QUERY] = "maxResults" } },
                NextToken = { type = stype.STRING, traits = { [strait.HTTP_QUERY] = "nextToken" } },
            },
        },
    }
    local req, err = protocol:serialize({ MaxResults = 10 }, op)
    assert(not err)
    assert_eq(req.url, "/items?maxResults=10")
end)

-- httpQueryParams (map -> query string)
test("serialize: httpQueryParams spreads map into query", function()
    local op = {
        name = "Search",
        http_method = "GET",
        http_path = "/search",
        input_schema = {
            type = stype.STRUCTURE,
            members = {
                Params = { type = stype.MAP, traits = { [strait.HTTP_QUERY_PARAMS] = true } },
            },
        },
    }
    local req, err = protocol:serialize({ Params = { foo = "bar", baz = "qux" } }, op)
    assert(not err)
    assert_eq(req.url, "/search?baz=qux&foo=bar")
end)

-- HTTP headers
test("serialize: header bindings", function()
    local op = {
        name = "PutItem",
        http_method = "PUT",
        http_path = "/items",
        input_schema = {
            type = stype.STRUCTURE,
            members = {
                Token = { type = stype.STRING, traits = { [strait.HTTP_HEADER] = "X-Token" } },
                Name = { type = stype.STRING },
            },
        },
    }
    local req, err = protocol:serialize({ Token = "secret", Name = "foo" }, op)
    assert(not err)
    assert_eq(req.headers["X-Token"], "secret")
    local body = http.read_all(req.body)
    assert_eq(body, '{"Name":"foo"}')
end)

-- Prefix headers
test("serialize: prefix headers", function()
    local op = {
        name = "PutItem",
        http_method = "PUT",
        http_path = "/items",
        input_schema = {
            type = stype.STRUCTURE,
            members = {
                Meta = { type = stype.MAP, traits = { [strait.HTTP_PREFIX_HEADERS] = "X-Meta-" } },
            },
        },
    }
    local req, err = protocol:serialize({ Meta = { color = "red", size = "large" } }, op)
    assert(not err)
    assert_eq(req.headers["X-Meta-color"], "red")
    assert_eq(req.headers["X-Meta-size"], "large")
end)

-- @httpPayload with structure
test("serialize: httpPayload structure is the entire body", function()
    local op = {
        name = "PutData",
        http_method = "PUT",
        http_path = "/data/{Id}",
        input_schema = {
            type = stype.STRUCTURE,
            members = {
                Id = { type = stype.STRING, traits = { [strait.HTTP_LABEL] = true } },
                Data = {
                    type = stype.STRUCTURE,
                    traits = { [strait.HTTP_PAYLOAD] = true },
                    members = {
                        Name = { type = stype.STRING },
                        Value = { type = stype.INTEGER },
                    },
                },
            },
        },
    }
    local req, err = protocol:serialize({ Id = "x", Data = { Name = "foo", Value = 42 } }, op)
    assert(not err)
    assert_eq(req.url, "/data/x")
    assert_eq(req.headers["Content-Type"], "application/json")
    local body = http.read_all(req.body)
    assert_eq(body, '{"Name":"foo","Value":42}')
end)

-- @httpPayload with blob
test("serialize: httpPayload blob is raw body", function()
    local op = {
        name = "Upload",
        http_method = "PUT",
        http_path = "/upload",
        input_schema = {
            type = stype.STRUCTURE,
            members = {
                Body = { type = stype.BLOB, traits = { [strait.HTTP_PAYLOAD] = true } },
            },
        },
    }
    local req, err = protocol:serialize({ Body = "raw bytes here" }, op)
    assert(not err)
    assert_eq(req.headers["Content-Type"], "application/octet-stream")
    assert_eq(http.read_all(req.body), "raw bytes here")
end)

-- @httpPayload with string
test("serialize: httpPayload string is raw body", function()
    local op = {
        name = "PutText",
        http_method = "PUT",
        http_path = "/text",
        input_schema = {
            type = stype.STRUCTURE,
            members = {
                Content = { type = stype.STRING, traits = { [strait.HTTP_PAYLOAD] = true } },
            },
        },
    }
    local req, err = protocol:serialize({ Content = "hello world" }, op)
    assert(not err)
    assert_eq(http.read_all(req.body), "hello world")
end)

-- json_name is respected
test("serialize: json_name trait used for body members", function()
    local op = {
        name = "CreateThing",
        http_method = "POST",
        http_path = "/things",
        input_schema = {
            type = stype.STRUCTURE,
            members = {
                TheName = { type = stype.STRING, traits = { [strait.JSON_NAME] = "the_name" } },
            },
        },
    }
    local req, err = protocol:serialize({ TheName = "foo" }, op)
    assert(not err)
    local body = http.read_all(req.body)
    assert_eq(body, '{"the_name":"foo"}')
end)

-- Mixed: labels + query + headers + body
test("serialize: mixed bindings", function()
    local op = {
        name = "UpdateItem",
        http_method = "PUT",
        http_path = "/tables/{Table}/items/{Id}",
        input_schema = {
            type = stype.STRUCTURE,
            members = {
                Table = { type = stype.STRING, traits = { [strait.HTTP_LABEL] = true } },
                Id = { type = stype.STRING, traits = { [strait.HTTP_LABEL] = true } },
                Version = { type = stype.INTEGER, traits = { [strait.HTTP_QUERY] = "version" } },
                IfMatch = { type = stype.STRING, traits = { [strait.HTTP_HEADER] = "If-Match" } },
                Name = { type = stype.STRING },
                Value = { type = stype.INTEGER },
            },
        },
    }
    local req, err = protocol:serialize({
        Table = "users", Id = "42", Version = 3, IfMatch = "etag1",
        Name = "updated", Value = 99,
    }, op)
    assert(not err)
    assert_eq(req.method, "PUT")
    assert_eq(req.url, "/tables/users/items/42?version=3")
    assert_eq(req.headers["If-Match"], "etag1")
    assert_eq(req.headers["Content-Type"], "application/json")
    local body = http.read_all(req.body)
    assert_eq(body, '{"Name":"updated","Value":99}')
end)

-- nil input
test("serialize: nil input", function()
    local op = {
        name = "ListThings",
        http_method = "GET",
        http_path = "/things",
        input_schema = { type = stype.STRUCTURE },
    }
    local req, err = protocol:serialize(nil, op)
    assert(not err)
    assert_eq(req.url, "/things")
end)

-- ============================================================
-- Deserialize tests
-- ============================================================

-- Simple body deserialization
test("deserialize: body-only members", function()
    local op = {
        name = "GetThing",
        output_schema = {
            type = stype.STRUCTURE,
            members = {
                Name = { type = stype.STRING },
                Count = { type = stype.INTEGER },
            },
        },
    }
    local resp = {
        status_code = 200,
        headers = {},
        body = http.string_reader('{"Name":"foo","Count":5}'),
    }
    local out, err = protocol:deserialize(resp, op)
    assert(not err, tostring(err and err.message))
    assert_eq(out.Name, "foo")
    assert_eq(out.Count, 5)
end)

-- httpResponseCode
test("deserialize: httpResponseCode binding", function()
    local op = {
        name = "CreateThing",
        output_schema = {
            type = stype.STRUCTURE,
            members = {
                StatusCode = { type = stype.INTEGER, traits = { [strait.HTTP_RESPONSE_CODE] = true } },
                Id = { type = stype.STRING },
            },
        },
    }
    local resp = {
        status_code = 201,
        headers = {},
        body = http.string_reader('{"Id":"abc"}'),
    }
    local out, err = protocol:deserialize(resp, op)
    assert(not err)
    assert_eq(out.StatusCode, 201)
    assert_eq(out.Id, "abc")
end)

-- httpHeader deserialization
test("deserialize: header bindings", function()
    local op = {
        name = "GetThing",
        output_schema = {
            type = stype.STRUCTURE,
            members = {
                RequestId = { type = stype.STRING, traits = { [strait.HTTP_HEADER] = "x-request-id" } },
                Name = { type = stype.STRING },
            },
        },
    }
    local resp = {
        status_code = 200,
        headers = { ["x-request-id"] = "req-123" },
        body = http.string_reader('{"Name":"foo"}'),
    }
    local out, err = protocol:deserialize(resp, op)
    assert(not err)
    assert_eq(out.RequestId, "req-123")
    assert_eq(out.Name, "foo")
end)

-- httpHeader boolean
test("deserialize: boolean header", function()
    local op = {
        name = "GetThing",
        output_schema = {
            type = stype.STRUCTURE,
            members = {
                Exists = { type = stype.BOOLEAN, traits = { [strait.HTTP_HEADER] = "x-exists" } },
            },
        },
    }
    local resp = {
        status_code = 200,
        headers = { ["x-exists"] = "true" },
        body = http.string_reader(""),
    }
    local out, err = protocol:deserialize(resp, op)
    assert(not err)
    assert_eq(out.Exists, true)
end)

-- httpHeader integer
test("deserialize: integer header", function()
    local op = {
        name = "GetThing",
        output_schema = {
            type = stype.STRUCTURE,
            members = {
                Count = { type = stype.INTEGER, traits = { [strait.HTTP_HEADER] = "x-count" } },
            },
        },
    }
    local resp = {
        status_code = 200,
        headers = { ["x-count"] = "42" },
        body = http.string_reader(""),
    }
    local out, err = protocol:deserialize(resp, op)
    assert(not err)
    assert_eq(out.Count, 42)
end)

-- httpPrefixHeaders
test("deserialize: prefix headers", function()
    local op = {
        name = "GetThing",
        output_schema = {
            type = stype.STRUCTURE,
            members = {
                Meta = { type = stype.MAP, traits = { [strait.HTTP_PREFIX_HEADERS] = "X-Meta-" } },
            },
        },
    }
    local resp = {
        status_code = 200,
        headers = { ["x-meta-color"] = "red", ["x-meta-size"] = "large", ["content-type"] = "application/json" },
        body = http.string_reader(""),
    }
    local out, err = protocol:deserialize(resp, op)
    assert(not err)
    assert(out.Meta, "expected Meta")
    assert_eq(out.Meta["color"], "red")
    assert_eq(out.Meta["size"], "large")
end)

-- httpPayload structure
test("deserialize: httpPayload structure", function()
    local op = {
        name = "GetData",
        output_schema = {
            type = stype.STRUCTURE,
            members = {
                Data = {
                    type = stype.STRUCTURE,
                    traits = { [strait.HTTP_PAYLOAD] = true },
                    members = {
                        Name = { type = stype.STRING },
                        Value = { type = stype.INTEGER },
                    },
                },
            },
        },
    }
    local resp = {
        status_code = 200,
        headers = {},
        body = http.string_reader('{"Name":"foo","Value":42}'),
    }
    local out, err = protocol:deserialize(resp, op)
    assert(not err)
    assert(out.Data, "expected Data")
    assert_eq(out.Data.Name, "foo")
    assert_eq(out.Data.Value, 42)
end)

-- httpPayload blob
test("deserialize: httpPayload blob", function()
    local op = {
        name = "Download",
        output_schema = {
            type = stype.STRUCTURE,
            members = {
                Body = { type = stype.BLOB, traits = { [strait.HTTP_PAYLOAD] = true } },
            },
        },
    }
    local resp = {
        status_code = 200,
        headers = {},
        body = http.string_reader("raw bytes"),
    }
    local out, err = protocol:deserialize(resp, op)
    assert(not err)
    assert_eq(out.Body, "raw bytes")
end)

-- Empty body success
test("deserialize: empty body returns empty output", function()
    local op = {
        name = "DeleteThing",
        output_schema = { type = stype.STRUCTURE },
    }
    local resp = {
        status_code = 204,
        headers = {},
        body = http.string_reader(""),
    }
    local out, err = protocol:deserialize(resp, op)
    assert(not err)
    assert(out, "expected non-nil output")
end)

-- Error: x-amzn-errortype header
test("deserialize: error from x-amzn-errortype header", function()
    local op = {
        name = "GetThing",
        output_schema = { type = stype.STRUCTURE },
    }
    local resp = {
        status_code = 404,
        headers = { ["x-amzn-errortype"] = "NotFoundException" },
        body = http.string_reader('{"message":"thing not found"}'),
    }
    local out, err = protocol:deserialize(resp, op)
    assert(not out)
    assert_eq(err.type, "api")
    assert_eq(err.code, "NotFoundException")
    assert_eq(err.message, "thing not found")
    assert_eq(err.status_code, 404)
end)

-- Error: __type in body
test("deserialize: error from __type in body", function()
    local op = {
        name = "GetThing",
        output_schema = { type = stype.STRUCTURE },
    }
    local resp = {
        status_code = 400,
        headers = {},
        body = http.string_reader('{"__type":"com.example#ValidationException","message":"bad input"}'),
    }
    local out, err = protocol:deserialize(resp, op)
    assert(not out)
    assert_eq(err.code, "ValidationException")
    assert_eq(err.message, "bad input")
end)

-- Error: empty body
test("deserialize: error with empty body", function()
    local op = {
        name = "GetThing",
        output_schema = { type = stype.STRUCTURE },
    }
    local resp = {
        status_code = 500,
        headers = {},
        body = http.string_reader(""),
    }
    local _, err = protocol:deserialize(resp, op)
    assert_eq(err.type, "api")
    assert_eq(err.code, "UnknownError")
    assert_eq(err.status_code, 500)
end)

-- Mixed output: headers + body + response code
test("deserialize: mixed output bindings", function()
    local op = {
        name = "CreateThing",
        output_schema = {
            type = stype.STRUCTURE,
            members = {
                StatusCode = { type = stype.INTEGER, traits = { [strait.HTTP_RESPONSE_CODE] = true } },
                RequestId = { type = stype.STRING, traits = { [strait.HTTP_HEADER] = "x-request-id" } },
                Id = { type = stype.STRING },
                Name = { type = stype.STRING },
            },
        },
    }
    local resp = {
        status_code = 201,
        headers = { ["x-request-id"] = "req-456" },
        body = http.string_reader('{"Id":"thing-1","Name":"foo"}'),
    }
    local out, err = protocol:deserialize(resp, op)
    assert(not err)
    assert_eq(out.StatusCode, 201)
    assert_eq(out.RequestId, "req-456")
    assert_eq(out.Id, "thing-1")
    assert_eq(out.Name, "foo")
end)

print(string.format("\nAll %d restJson1 protocol tests passed.", pass_count))
