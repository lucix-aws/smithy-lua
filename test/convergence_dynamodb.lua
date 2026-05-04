-- Phase 3 Convergence: real DynamoDB ListTables call.
-- Wires: DynamoDB client + awsJson 1.0 protocol + SigV4 signer + env creds + real HTTP
--
-- Usage: cd smithy-lua && luajit test/convergence_sts.lua
-- Requires: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY set in environment

local root = debug.getinfo(1, "S").source:match("@(.*/)")
package.path = root .. "../runtime/?.lua;"
    .. root .. "../runtime/?/init.lua;"
    .. package.path

local dynamodb = require("dynamodb.client")
local protocol_json = require("protocol.awsjson")
local signer = require("signer")
local env_creds = require("credentials.environment")
local http_resolver = require("http.client")

-- Resolve HTTP client
local http_client, err = http_resolver.resolve()
if err then
    print("FATAL: no HTTP client: " .. err.message)
    os.exit(1)
end
print("[ok] HTTP client resolved")

-- Build DynamoDB client
local region = os.getenv("AWS_REGION") or "us-east-1"
local client = dynamodb.new({
    region = region,
    protocol = protocol_json.new({ version = "1.0", service_id = "DynamoDB_20120810" }),
    http_client = http_client,
    identity_resolver = env_creds.new(),
    signer = signer.sign,
    endpoint_provider = function(params)
        return { url = "https://dynamodb." .. params.region .. ".amazonaws.com" }, nil
    end,
})

print("[ok] DynamoDB client constructed (region=" .. region .. ")")
print("[..] calling ListTables...")

local output, err = client:listTables()
if err then
    print("[FAIL] " .. err.type .. " error: " .. (err.code or "?") .. ": " .. (err.message or "?"))
    if err.status_code then print("       status: " .. err.status_code) end
    os.exit(1)
end

print("[ok] ListTables succeeded!")
print("  Tables: " .. table.concat(output.TableNames or {}, ", "))
