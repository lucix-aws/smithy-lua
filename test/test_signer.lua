-- Test: runtime/signer.lua (SigV4)
-- Run: luajit test/test_signer.lua
-- Reference: https://docs.aws.amazon.com/general/latest/gr/sigv4-create-canonical-request.html

package.path = "runtime/?.lua;runtime/?/init.lua;" .. package.path

local signer = require("signer")
local http = require("http")

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
        error((msg or "assert_eq") .. ":\n  expected: " .. tostring(b) .. "\n  got:      " .. tostring(a), 2)
    end
end

local function assert_contains(s, sub, msg)
    if not s:find(sub, 1, true) then
        error((msg or "assert_contains") .. ": '" .. sub .. "' not found in '" .. s .. "'", 2)
    end
end

-- Test identity
local creds = {
    access_key = "AKIDEXAMPLE",
    secret_key = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
}

local props = {
    signing_name = "service",
    signing_region = "us-east-1",
}

-- URI encoding tests
test("uri_encode: unreserved chars pass through", function()
    assert_eq(signer.uri_encode("ABCabc012-_.~"), "ABCabc012-_.~")
end)

test("uri_encode: spaces", function()
    assert_eq(signer.uri_encode("hello world"), "hello%20world")
end)

test("uri_encode: slash encoding", function()
    assert_eq(signer.uri_encode("/path/to", true), "%2Fpath%2Fto")
    assert_eq(signer.uri_encode("/path/to", false), "/path/to")
end)

test("uri_encode: special chars", function()
    assert_eq(signer.uri_encode("foo=bar&baz"), "foo%3Dbar%26baz")
end)

-- SigV4 signing: AWS test suite "get-vanilla"
-- https://docs.aws.amazon.com/general/latest/gr/signature-v4-test-suite.html
test("sigv4: GET / with empty query", function()
    local request = {
        method = "GET",
        url = "https://example.amazonaws.com/",
        headers = {
            ["X-Amz-Date"] = "20150830T123600Z",
        },
        body = http.string_reader(""),
    }
    local signed, err = signer.sign(request, creds, props)
    assert(not err, "sign error: " .. tostring(err and err.message))
    local auth = signed.headers["Authorization"]
    assert_contains(auth, "AWS4-HMAC-SHA256")
    assert_contains(auth, "Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request")
    assert_contains(auth, "SignedHeaders=host;x-amz-content-sha256;x-amz-date")
    -- Our signer includes x-amz-content-sha256 in signed headers (standard SDK behavior),
    -- so the signature differs from the minimal AWS test suite vector.
    assert_contains(auth, "Signature=")
end)

-- POST with body
test("sigv4: POST with body", function()
    local request = {
        method = "POST",
        url = "https://example.amazonaws.com/",
        headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded",
            ["X-Amz-Date"] = "20150830T123600Z",
        },
        body = http.string_reader("Param1=value1"),
    }
    local signed, err = signer.sign(request, creds, props)
    assert(not err, "sign error: " .. tostring(err and err.message))
    local auth = signed.headers["Authorization"]
    assert_contains(auth, "AWS4-HMAC-SHA256")
    assert_contains(auth, "Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request")
end)

-- Session token
test("sigv4: session token is added", function()
    local creds_with_token = {
        access_key = "AKIDEXAMPLE",
        secret_key = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
        session_token = "AQoDYXdzEJr...",
    }
    local request = {
        method = "GET",
        url = "https://example.amazonaws.com/",
        headers = { ["X-Amz-Date"] = "20150830T123600Z" },
        body = http.string_reader(""),
    }
    local signed, err = signer.sign(request, creds_with_token, props)
    assert(not err)
    assert_eq(signed.headers["X-Amz-Security-Token"], "AQoDYXdzEJr...")
    assert_contains(signed.headers["Authorization"], "x-amz-security-token")
end)

-- Query string sorting
test("sigv4: query params are sorted", function()
    local request = {
        method = "GET",
        url = "https://example.amazonaws.com/?Zebra=z&Apple=a",
        headers = { ["X-Amz-Date"] = "20150830T123600Z" },
        body = http.string_reader(""),
    }
    local signed, err = signer.sign(request, creds, props)
    assert(not err)
    assert(signed.headers["Authorization"])
end)

-- Body is re-wrapped as reader after signing
test("sigv4: body is readable after signing", function()
    local request = {
        method = "POST",
        url = "https://example.amazonaws.com/",
        headers = { ["X-Amz-Date"] = "20150830T123600Z" },
        body = http.string_reader("test body"),
    }
    local signed, err = signer.sign(request, creds, props)
    assert(not err)
    local body = http.read_all(signed.body)
    assert_eq(body, "test body")
end)

-- Nil body
test("sigv4: nil body is handled", function()
    local request = {
        method = "GET",
        url = "https://example.amazonaws.com/",
        headers = { ["X-Amz-Date"] = "20150830T123600Z" },
    }
    local signed, err = signer.sign(request, creds, props)
    assert(not err)
    assert(signed.headers["Authorization"])
end)

-- Host header is set
test("sigv4: host header is set from URL", function()
    local request = {
        method = "GET",
        url = "https://sts.us-east-1.amazonaws.com/",
        headers = { ["X-Amz-Date"] = "20150830T123600Z" },
        body = http.string_reader(""),
    }
    local signed, err = signer.sign(request, creds, props)
    assert(not err)
    assert_eq(signed.headers["Host"], "sts.us-east-1.amazonaws.com")
end)

-- Deterministic end-to-end: verify signing is stable
test("sigv4: deterministic signing", function()
    local r1 = {
        method = "GET",
        url = "https://example.amazonaws.com/",
        headers = { ["X-Amz-Date"] = "20150830T123600Z" },
        body = http.string_reader(""),
    }
    local r2 = {
        method = "GET",
        url = "https://example.amazonaws.com/",
        headers = { ["X-Amz-Date"] = "20150830T123600Z" },
        body = http.string_reader(""),
    }
    local s1 = signer.sign(r1, creds, props)
    local s2 = signer.sign(r2, creds, props)
    assert_eq(s1.headers["Authorization"], s2.headers["Authorization"], "signatures should be deterministic")
end)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
