-- Type-check test: exercise the HTTP client and async types

local async = require("smithy.async")
local http = require("smithy.http")
local curl_async = require("smithy.http.curl_async")

local client: http.HttpClient = curl_async.new()

local request: http.Request = {
    method = "GET",
    url = "https://httpbin.org/get",
    headers = {},
}

local op: async.Operation = client:roundtrip(request)
local response, err = op:await()
