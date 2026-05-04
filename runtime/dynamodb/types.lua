-- Minimal DynamoDB types for convergence testing.

local schema = require("schema")

local M = {}

M.ListTablesInput = {
    type = schema.type.STRUCTURE,
    members = {
        ExclusiveStartTableName = { type = schema.type.STRING },
        Limit = { type = schema.type.INTEGER },
    },
}

M.ListTablesOutput = {
    type = schema.type.STRUCTURE,
    members = {
        TableNames = {
            type = schema.type.LIST,
            member = { type = schema.type.STRING },
        },
        LastEvaluatedTableName = { type = schema.type.STRING },
    },
}

return M
