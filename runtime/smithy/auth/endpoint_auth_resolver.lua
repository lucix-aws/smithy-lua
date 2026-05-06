-- smithy-lua runtime: endpoint-driven auth scheme resolver
-- For services like S3 and EventBridge where endpoint rules determine the auth
-- scheme (e.g. sigv4a for MRAP) rather than just adjusting signer properties.

local M = {}

-- Mapping from endpoint ruleset auth scheme names to Smithy auth scheme IDs.
local SCHEME_MAP = {
    sigv4 = "aws.auth#sigv4",
    sigv4a = "aws.auth#sigv4a",
    ["sigv4-s3express"] = "com.amazonaws.s3#sigv4express",
}

--- Create an endpoint-driven auth scheme resolver.
--- The returned resolver resolves the endpoint first, then uses the endpoint's
--- authSchemes as the authoritative list of auth options. Falls back to the
--- operation's modeled auth schemes if the endpoint doesn't specify any.
---
--- @param config table: client config (needs endpoint_provider, region, etc.)
--- @return function: auth_scheme_resolver(operation, input) -> options
function M.new(config)
    return function(operation, input)
        -- Build endpoint params (same logic as the pipeline)
        local ep_params = {}
        if config.region then ep_params.Region = config.region end
        if config.use_fips ~= nil then ep_params.UseFIPS = config.use_fips end
        if config.use_dual_stack ~= nil then ep_params.UseDualStack = config.use_dual_stack end
        if config.endpoint_url then ep_params.Endpoint = config.endpoint_url end
        if config.disable_s3_express_session_auth then
            ep_params.DisableS3ExpressSessionAuth = true
        end
        if operation.context_params and input then
            for param_name, input_field in pairs(operation.context_params) do
                ep_params[param_name] = input[input_field]
            end
        end

        -- Resolve endpoint
        local endpoint, err = config.endpoint_provider(ep_params)
        if err then
            -- Fall back to modeled auth schemes on endpoint resolution failure;
            -- the pipeline will surface the endpoint error later.
            return operation.auth_schemes or {}
        end

        -- Check if endpoint specifies auth schemes
        local props = endpoint.properties
        if not props or not props.authSchemes or #props.authSchemes == 0 then
            return operation.auth_schemes or {}
        end

        -- Build options from endpoint auth schemes
        local options = {}
        for _, ep_scheme in ipairs(props.authSchemes) do
            local scheme_id = SCHEME_MAP[ep_scheme.name] or ("aws.auth#" .. ep_scheme.name)
            local signer_properties = {}
            if ep_scheme.signingName then
                signer_properties.signing_name = ep_scheme.signingName
            end
            if ep_scheme.signingRegion then
                signer_properties.signing_region = ep_scheme.signingRegion
            end
            if ep_scheme.signingRegionSet then
                signer_properties.signing_region_set = ep_scheme.signingRegionSet
            end
            if ep_scheme.disableDoubleEncoding ~= nil then
                signer_properties.disable_double_encoding = ep_scheme.disableDoubleEncoding
            end
            options[#options + 1] = {
                scheme_id = scheme_id,
                signer_properties = signer_properties,
            }
        end

        -- Pass bucket context for S3Express identity resolution
        if ep_params.Bucket then
            config._s3express_bucket = ep_params.Bucket
        end

        return options
    end
end

return M
