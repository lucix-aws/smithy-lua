local assert = require("luassert") as any
-- Test: runtime/signer.lua (SigV4)
-- Reference: https://docs.aws.amazon.com/general/latest/gr/sigv4-create-canonical-request.html

local signer = require("smithy.signer")
local http = require("smithy.http")

local function assert_contains(s: string, sub: string, msg: string)
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

describe("signer", function()
    -- URI encoding tests
    it("uri_encode: unreserved chars pass through", function()
        assert.are.equal("ABCabc012-_.~", signer.uri_encode("ABCabc012-_.~"))
    end)

    it("uri_encode: spaces", function()
        assert.are.equal("hello%20world", signer.uri_encode("hello world"))
    end)

    it("uri_encode: slash encoding", function()
        assert.are.equal("%2Fpath%2Fto", signer.uri_encode("/path/to", true))
        assert.are.equal("/path/to", signer.uri_encode("/path/to", false))
    end)

    it("uri_encode: special chars", function()
        assert.are.equal("foo%3Dbar%26baz", signer.uri_encode("foo=bar&baz"))
    end)

    -- SigV4 signing: AWS test suite "get-vanilla"
    it("sigv4: GET / with empty query", function()
        local request = {
            method = "GET",
            url = "https://example.amazonaws.com/",
            headers = {
                ["X-Amz-Date"] = "20150830T123600Z",
            },
            body = http.string_reader(""),
        }
        local signed, err = signer.sign(request, creds, props)
        assert(not err, "sign error: " .. tostring(err and (err as {string:any}).message))
        local auth = (signed as {string:any}).headers["Authorization"] as string
        assert_contains(auth, "AWS4-HMAC-SHA256")
        assert_contains(auth, "Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request")
        assert_contains(auth, "SignedHeaders=host;x-amz-content-sha256;x-amz-date")
        assert_contains(auth, "Signature=")
    end)

    -- POST with body
    it("sigv4: POST with body", function()
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
        assert(not err, "sign error: " .. tostring(err and (err as {string:any}).message))
        local auth = (signed as {string:any}).headers["Authorization"] as string
        assert_contains(auth, "AWS4-HMAC-SHA256")
        assert_contains(auth, "Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request")
    end)

    -- Session token
    it("sigv4: session token is added", function()
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
        local hdrs = (signed as {string:any}).headers as {string:any}
        assert.are.equal("AQoDYXdzEJr...", hdrs["X-Amz-Security-Token"])
        assert_contains(hdrs["Authorization"] as string, "x-amz-security-token")
    end)

    -- Query string sorting
    it("sigv4: query params are sorted", function()
        local request = {
            method = "GET",
            url = "https://example.amazonaws.com/?Zebra=z&Apple=a",
            headers = { ["X-Amz-Date"] = "20150830T123600Z" },
            body = http.string_reader(""),
        }
        local signed, err = signer.sign(request, creds, props)
        assert(not err)
        assert((signed as {string:any}).headers["Authorization"])
    end)

    -- Body is re-wrapped as reader after signing
    it("sigv4: body is readable after signing", function()
        local request = {
            method = "POST",
            url = "https://example.amazonaws.com/",
            headers = { ["X-Amz-Date"] = "20150830T123600Z" },
            body = http.string_reader("test body"),
        }
        local signed, err = signer.sign(request, creds, props)
        assert(not err)
        local body = http.read_all((signed as {string:any}).body)
        assert.are.equal("test body", body)
    end)

    -- Nil body
    it("sigv4: nil body is handled", function()
        local request = {
            method = "GET",
            url = "https://example.amazonaws.com/",
            headers = { ["X-Amz-Date"] = "20150830T123600Z" },
        }
        local signed, err = signer.sign(request, creds, props)
        assert(not err)
        assert((signed as {string:any}).headers["Authorization"])
    end)

    -- Host header is set
    it("sigv4: host header is set from URL", function()
        local request = {
            method = "GET",
            url = "https://sts.us-east-1.amazonaws.com/",
            headers = { ["X-Amz-Date"] = "20150830T123600Z" },
            body = http.string_reader(""),
        }
        local signed, err = signer.sign(request, creds, props)
        assert(not err)
        assert.are.equal("sts.us-east-1.amazonaws.com", (signed as {string:any}).headers["Host"])
    end)

    -- Deterministic end-to-end: verify signing is stable
    it("sigv4: deterministic signing", function()
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
        assert.are.equal(
            (s2 as {string:any}).headers["Authorization"],
            (s1 as {string:any}).headers["Authorization"],
            "signatures should be deterministic")
    end)
end)
