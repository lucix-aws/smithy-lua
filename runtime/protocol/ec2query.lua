-- smithy-lua runtime: ec2Query protocol
-- Variant of awsQuery for EC2 (always-flattened lists, capitalized keys,
-- ec2QueryName trait, different error/response wrapping).

local awsquery = require("protocol.awsquery")

local M = {}
M.__index = M

function M.new(settings)
    settings = settings or {}
    settings.ec2 = true
    return awsquery.new(settings)
end

return M
