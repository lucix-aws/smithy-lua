-- smithy-lua runtime: ec2Query protocol

local awsquery = require("smithy.protocol.awsquery")

local record M
end

function M.new(settings: {string:any}): awsquery
    settings = settings or {}
    settings.ec2 = true
    return awsquery.new(settings)
end

return M
