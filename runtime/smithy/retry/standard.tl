-- smithy-lua runtime: AWS standard retry strategy

local error_mod = require("smithy.error")
local retry_mod = require("smithy.retry")

local record standard_mod
    record Options
        max_attempts: integer
        max_backoff: number
        rate_tokens: integer
        retry_cost: integer
        timeout_cost: integer
        no_retry_increment: integer
    end

    DEFAULT_MAX_ATTEMPTS: integer
    DEFAULT_MAX_BACKOFF: number
    DEFAULT_RATE_TOKENS: integer
    DEFAULT_RETRY_COST: integer
    DEFAULT_TIMEOUT_COST: integer
    DEFAULT_NO_RETRY_INCREMENT: integer
end

standard_mod.DEFAULT_MAX_ATTEMPTS = 3
standard_mod.DEFAULT_MAX_BACKOFF = 20
standard_mod.DEFAULT_RATE_TOKENS = 500
standard_mod.DEFAULT_RETRY_COST = 5
standard_mod.DEFAULT_TIMEOUT_COST = 10
standard_mod.DEFAULT_NO_RETRY_INCREMENT = 1

math.randomseed(os.time())

local function backoff_delay(attempt: integer, max_backoff: number): number
    if attempt <= 0 then return 0 end
    local ceil = math.min(2 ^ attempt, max_backoff)
    return math.random() * ceil
end

function standard_mod.new(opts: standard_mod.Options): retry_mod.Retryer
    opts = opts or {} as standard_mod.Options
    local max_attempts = opts.max_attempts or standard_mod.DEFAULT_MAX_ATTEMPTS
    local max_backoff = opts.max_backoff or standard_mod.DEFAULT_MAX_BACKOFF
    local retry_cost = opts.retry_cost or standard_mod.DEFAULT_RETRY_COST
    local timeout_cost = opts.timeout_cost or standard_mod.DEFAULT_TIMEOUT_COST
    local no_retry_increment = opts.no_retry_increment or standard_mod.DEFAULT_NO_RETRY_INCREMENT

    local capacity = opts.rate_tokens or standard_mod.DEFAULT_RATE_TOKENS
    local max_capacity = capacity

    return {
        acquire_token = function(_self: retry_mod.Retryer): retry_mod.Token, any
            return { attempt = 0 } as retry_mod.Token
        end,

        retry_token = function(_self: retry_mod.Retryer, token: retry_mod.Token, err: any): number, any
            token.attempt = token.attempt + 1
            if token.attempt >= max_attempts then
                return nil, err
            end
            if not error_mod.is_retryable(err as error_mod.Error) then
                return nil, err
            end

            local cost = error_mod.is_timeout(err as error_mod.Error) and timeout_cost or retry_cost
            if capacity < cost then
                return nil, err
            end
            capacity = capacity - cost
            token.cost = cost

            return backoff_delay(token.attempt, max_backoff)
        end,

        record_success = function(_self: retry_mod.Retryer, token: retry_mod.Token)
            if token.cost then
                capacity = math.min(max_capacity, capacity + token.cost)
            else
                capacity = math.min(max_capacity, capacity + no_retry_increment)
            end
        end,
    }
end

return standard_mod
