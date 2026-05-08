-- smithy-lua runtime: endpoint-driven auth scheme resolver

local record M
    new: function(config: {string:any}): function(any, any, any): {any}
end

local SCHEME_MAP: {string:string} = {
    sigv4 = "aws.auth#sigv4",
    sigv4a = "aws.auth#sigv4a",
    ["sigv4-s3express"] = "com.amazonaws.s3#sigv4express",
}

function M.new(config: {string:any}): function(any, any, any): {any}
    local traits = require("smithy.traits")
    return function(service: any, operation: any, input: {string:any}): {any}
        local ep_params: {string:any} = {}
        if config.region then ep_params.Region = config.region end
        if config.use_fips ~= nil then ep_params.UseFIPS = config.use_fips end
        if config.use_dual_stack ~= nil then ep_params.UseDualStack = config.use_dual_stack end
        if config.endpoint_url then ep_params.Endpoint = config.endpoint_url end
        if config.disable_s3_express_session_auth then
            ep_params.DisableS3ExpressSessionAuth = true
        end
        local op_trait = (operation as {string:any}).trait as function(any, any): any
        local svc_trait = (service as {string:any}).trait as function(any, any): any
        local static_ctx = op_trait(operation, traits.STATIC_CONTEXT_PARAMS)
        if static_ctx then
            for param_name, param_def in pairs(static_ctx as {string:{string:any}}) do
                ep_params[param_name] = param_def.value
            end
        end
        local ctx_params = op_trait(operation, traits.CONTEXT_PARAMS)
        if ctx_params and input then
            for param_name, input_field in pairs(ctx_params as {string:string}) do
                ep_params[param_name] = input[input_field]
            end
        end

        local endpoint_provider = config.endpoint_provider as function({string:any}): {string:any}, string
        local endpoint, err = endpoint_provider(ep_params)
        if err then
            local auth_trait = op_trait(operation, traits.AUTH) or svc_trait(service, traits.AUTH)
            return (auth_trait or {}) as {any}
        end

        local props = endpoint.properties as {string:any}
        if not props or not props.authSchemes then
            local auth_trait = op_trait(operation, traits.AUTH) or svc_trait(service, traits.AUTH)
            return (auth_trait or {}) as {any}
        end

        local options: {any} = {}
        for _, ep_scheme in ipairs(props.authSchemes as {any}) do
            local ep = ep_scheme as {string:any}
            local scheme_id = SCHEME_MAP[ep.name as string] or ("aws.auth#" .. (ep.name as string))
            local signer_properties: {string:any} = {}
            if ep.signingName then
                signer_properties.signing_name = ep.signingName
            end
            if ep.signingRegion then
                signer_properties.signing_region = ep.signingRegion
            end
            if ep.signingRegionSet then
                signer_properties.signing_region_set = ep.signingRegionSet
            end
            if ep.disableDoubleEncoding ~= nil then
                signer_properties.disable_double_encoding = ep.disableDoubleEncoding
            end
            options[#options + 1] = {
                scheme_id = scheme_id,
                signer_properties = signer_properties,
            }
        end

        if ep_params.Bucket then
            config._s3express_bucket = ep_params.Bucket
        end

        return options
    end
end

return M
