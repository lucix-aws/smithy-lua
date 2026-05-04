-- Teal declarations for runtime/retry/standard.lua

local record M

    DEFAULT_MAX_ATTEMPTS: integer
    DEFAULT_MAX_BACKOFF: number
    DEFAULT_RATE_TOKENS: integer
    DEFAULT_RETRY_COST: integer
    DEFAULT_TIMEOUT_COST: integer
    DEFAULT_NO_RETRY_INCREMENT: integer

    record Options
        max_attempts: integer
        max_backoff: number
        rate_tokens: integer
        retry_cost: integer
        timeout_cost: integer
        no_retry_increment: integer
    end

    record Token
        attempt: integer
        cost: integer
    end

    record StandardRetryer
        acquire_token: function(self: StandardRetryer): Token, table
        retry_token: function(self: StandardRetryer, token: Token, err: table): number, table
        record_success: function(self: StandardRetryer, token: Token)
        available_capacity: function(self: StandardRetryer): integer
    end

    new: function(opts: Options): StandardRetryer
end

return M
