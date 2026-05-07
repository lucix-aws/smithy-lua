-- smithy-lua runtime: S3Express signer

local signer = require("smithy.signer")

local record M
    sign: function(request: any, identity: any, props: {string:any}): any, any
end

function M.sign(request: any, identity: any, props: {string:any}): any, any
    local req = request as {string:any}
    local id = identity as {string:any}
    local headers = req.headers as {string:string}
    if not headers then
        headers = {}
        req.headers = headers
    end
    headers["x-amz-s3session-token"] = id.session_token as string

    local signing_identity: {string:any} = {
        access_key = id.access_key,
        secret_key = id.secret_key,
    }
    return signer.sign(request, signing_identity, props)
end

return M
