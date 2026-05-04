-- Minimal STS types for convergence testing.
-- Hand-written to match codegen output format.

local schema = require("schema")

local M = {}

M.GetCallerIdentityInput = {
    type = schema.type.STRUCTURE,
    members = {},
}

M.GetCallerIdentityOutput = {
    type = schema.type.STRUCTURE,
    members = {
        Account = { type = schema.type.STRING },
        Arn = { type = schema.type.STRING },
        UserId = { type = schema.type.STRING },
    },
}

return M
