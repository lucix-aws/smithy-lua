-- Teal declarations for runtime/endpoint.lua

local record endpoint

    record Endpoint
        url: string
        headers: {string: {string}}
        properties: {string: any}
    end

    record Ruleset
        parameters: {string: ParameterDef}
        rules: {Rule}
    end

    record ParameterDef
        type: string
        required: boolean
        default: any
        builtIn: string
        documentation: string
    end

    record Rule
        type: string -- "endpoint" | "error" | "tree"
        conditions: {Condition}
        endpoint: EndpointDef
        error: any
        rules: {Rule}
    end

    record Condition
        fn: string
        argv: {any}
        assign: string
    end

    record EndpointDef
        url: any
        headers: {string: {any}}
        properties: {string: any}
    end

    record URL
        scheme: string
        authority: string
        path: string
        normalizedPath: string
        isIp: boolean
    end

    record ARN
        partition: string
        service: string
        region: string
        accountId: string
        resourceId: {string}
    end

    record Partition
        name: string
        dnsSuffix: string
        dualStackDnsSuffix: string
        supportsFIPS: boolean
        supportsDualStack: boolean
        implicitGlobalRegion: string
    end

    resolve: function(ruleset: Ruleset, params: {string: any}): Endpoint, string

end

return endpoint
