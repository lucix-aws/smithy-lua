-- Minimal DynamoDB client for convergence testing.

local base_client = require("client")
local types = require("dynamodb.types")

local M = {}

local Client = {}
Client.__index = Client
Client.invokeOperation = base_client.invokeOperation

function M.new(config)
    config.service_id = "DynamoDB_20120810"
    config.signing_name = "dynamodb"
    return setmetatable(base_client.new(config), Client)
end

function Client:listTables(input, options)
    return self:invokeOperation(input or {}, {
        name = "ListTables",
        input_schema = types.ListTablesInput,
        output_schema = types.ListTablesOutput,
        http_method = "POST",
        http_path = "/",
    }, options)
end

return M
