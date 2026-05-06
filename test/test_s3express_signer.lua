-- Test: S3Express signer
-- Run: luajit test/test_s3express_signer.lua

package.path = "runtime/?.lua;runtime/?/init.lua;" .. package.path

local s3express_signer = require("smithy.s3express_signer")
local http = require("smithy.http")

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

local function assert_not_contains(s, sub, msg)
    if s:find(sub, 1, true) then
        error((msg or "assert_not_contains") .. ": '" .. sub .. "' unexpectedly found in '" .. s .. "'", 2)
    end
end

-- S3Express credentials (as returned by CreateSession)
local s3express_creds = {
    access_key = "S3EXPRESSEXAMPLEKEY",
    secret_key = "s3expressexamplesecretkey1234567890",
    session_token = "s3express-session-token-value-xyz",
}

local props = {
    signing_name = "s3express",
    signing_region = "us-east-1",
    disable_double_encoding = true,
}

test("s3express signer adds x-amz-s3session-token header", function()
    local request = {
        method = "GET",
        url = "https://mybucket--use1-az1--x-s3.s3express-use1-az1.us-east-1.amazonaws.com/mykey",
        headers = {},
        body = http.string_reader(""),
    }

    local signed, err = s3express_signer.sign(request, s3express_creds, props)
    assert(signed, "signing failed: " .. tostring(err and err.message))
    assert_eq(signed.headers["x-amz-s3session-token"], "s3express-session-token-value-xyz")
end)

test("s3express signer does NOT add X-Amz-Security-Token", function()
    local request = {
        method = "GET",
        url = "https://mybucket--use1-az1--x-s3.s3express-use1-az1.us-east-1.amazonaws.com/mykey",
        headers = {},
        body = http.string_reader(""),
    }

    local signed, err = s3express_signer.sign(request, s3express_creds, props)
    assert(signed, "signing failed: " .. tostring(err and err.message))
    assert_eq(signed.headers["X-Amz-Security-Token"], nil, "X-Amz-Security-Token should not be set")
end)

test("s3express signer produces valid Authorization header", function()
    local request = {
        method = "PUT",
        url = "https://mybucket--use1-az1--x-s3.s3express-use1-az1.us-east-1.amazonaws.com/hello.txt",
        headers = {},
        body = http.string_reader("hello world"),
    }

    local signed, err = s3express_signer.sign(request, s3express_creds, props)
    assert(signed, "signing failed: " .. tostring(err and err.message))
    local auth_header = signed.headers["Authorization"]
    assert(auth_header, "Authorization header missing")
    assert_contains(auth_header, "AWS4-HMAC-SHA256")
    assert_contains(auth_header, "Credential=S3EXPRESSEXAMPLEKEY/")
    assert_contains(auth_header, "s3express/aws4_request")
end)

test("s3express signer includes x-amz-s3session-token in signed headers", function()
    local request = {
        method = "GET",
        url = "https://mybucket--use1-az1--x-s3.s3express-use1-az1.us-east-1.amazonaws.com/mykey",
        headers = {},
        body = http.string_reader(""),
    }

    local signed, err = s3express_signer.sign(request, s3express_creds, props)
    assert(signed, "signing failed: " .. tostring(err and err.message))
    local auth_header = signed.headers["Authorization"]
    assert_contains(auth_header, "x-amz-s3session-token", "session token header should be signed")
end)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
