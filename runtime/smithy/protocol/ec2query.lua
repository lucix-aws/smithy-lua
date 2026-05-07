

local awsquery = require("smithy.protocol.awsquery")

local M = {}


function M.new(settings)
   settings = settings or {}
   settings.ec2 = true
   return awsquery.new(settings)
end

return M
