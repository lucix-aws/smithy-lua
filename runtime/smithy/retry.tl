-- smithy-lua runtime: retry interface

local record M
    record RetryToken
        attempt: number
        cost: number
    end

    record RetryStrategy
        acquire_token: function(RetryStrategy): RetryToken, any
        retry_token: function(RetryStrategy, token: RetryToken, err: any): number, any
        record_success: function(RetryStrategy, token: RetryToken)
    end

    none: function(): RetryStrategy
end

function M.none(): M.RetryStrategy
    return {
        acquire_token = function(_self: M.RetryStrategy): M.RetryToken, any return { attempt = 0 } as M.RetryToken, nil end,
        retry_token = function(_self: M.RetryStrategy, _token: M.RetryToken, err: any): number, any return nil as number, err end,
        record_success = function(_self: M.RetryStrategy, _token: M.RetryToken) end,
    }
end

return M
