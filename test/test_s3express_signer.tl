local assert = require("luassert") as any
-- Test: S3Express signer

local s3express_signer = require("smithy.s3express_signer")
local http = require("smithy.http")

local function assert_contains(s: string, sub: string, msg: string)
    if not s:find(sub, 1, true) then
        error((msg or "assert_contains") .. ": '" .. sub .. "' not found in '" .. s .. "'", 2)
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

describe("s3express_signer", function()

it("adds x-amz-s3session-token header", function()
    local request = {
        method = "GET",
        url = "https://mybucket--use1-az1--x-s3.s3express-use1-az1.us-east-1.amazonaws.com/mykey",
        headers = {} as {string:string},
        body = http.string_reader(""),
    }
    local signed, err = s3express_signer.sign(request, s3express_creds, props)
    assert(signed, "signing failed: " .. tostring(err and (err as {string:string}).message))
    assert.are.equal("s3express-session-token-value-xyz", (signed as {string:any}).headers["x-amz-s3session-token"])
end)

it("does NOT add X-Amz-Security-Token", function()
    local request = {
        method = "GET",
        url = "https://mybucket--use1-az1--x-s3.s3express-use1-az1.us-east-1.amazonaws.com/mykey",
        headers = {} as {string:string},
        body = http.string_reader(""),
    }
    local signed, err = s3express_signer.sign(request, s3express_creds, props)
    assert(signed, "signing failed: " .. tostring(err and (err as {string:string}).message))
    assert.is_nil((signed as {string:any}).headers["X-Amz-Security-Token"])
end)

it("produces valid Authorization header", function()
    local request = {
        method = "PUT",
        url = "https://mybucket--use1-az1--x-s3.s3express-use1-az1.us-east-1.amazonaws.com/hello.txt",
        headers = {} as {string:string},
        body = http.string_reader("hello world"),
    }
    local signed, err = s3express_signer.sign(request, s3express_creds, props)
    assert(signed, "signing failed: " .. tostring(err and (err as {string:string}).message))
    local auth_header = (signed as {string:any}).headers["Authorization"] as string
    assert(auth_header, "Authorization header missing")
    assert_contains(auth_header, "AWS4-HMAC-SHA256")
    assert_contains(auth_header, "Credential=S3EXPRESSEXAMPLEKEY/")
    assert_contains(auth_header, "s3express/aws4_request")
end)

it("includes x-amz-s3session-token in signed headers", function()
    local request = {
        method = "GET",
        url = "https://mybucket--use1-az1--x-s3.s3express-use1-az1.us-east-1.amazonaws.com/mykey",
        headers = {} as {string:string},
        body = http.string_reader(""),
    }
    local signed, err = s3express_signer.sign(request, s3express_creds, props)
    assert(signed, "signing failed: " .. tostring(err and (err as {string:string}).message))
    local auth_header = (signed as {string:any}).headers["Authorization"] as string
    assert_contains(auth_header, "x-amz-s3session-token", "session token header should be signed")
end)

end)
