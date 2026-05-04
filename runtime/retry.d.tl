-- Teal declarations for runtime/retry.lua

local record M

    record Token
        {string: any}
    end

    record Retryer
        acquire_token: function(self: Retryer): Token, table
        retry_token: function(self: Retryer, token: Token, err: table): number, table
        record_success: function(self: Retryer, token: Token)
    end

    none: function(): Retryer
end

return M
