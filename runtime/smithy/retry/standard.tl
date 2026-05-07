local error_mod = require("smithy.error")

local record M
    DEFAULT_MAX_ATTEMPTS: number
    DEFAULT_MAX_BACKOFF: number
    DEFAULT_RATE_TOKENS: number
    DEFAULT_RETRY_COST: number
    DEFAULT_TIMEOUT_COST: number
    DEFAULT_NO_RETRY_INCREMENT: number
end

M.DEFAULT_MAX_ATTEMPTS = 3
M.DEFAULT_MAX_BACKOFF = 20
M.DEFAULT_RATE_TOKENS = 500
M.DEFAULT_RETRY_COST = 5
M.DEFAULT_TIMEOUT_COST = 10
M.DEFAULT_NO_RETRY_INCREMENT = 1

math.randomseed(os.time())

local function backoff_delay(attempt: number, max_backoff: number): number
    if attempt <= 0 then return 0 end
    local ceil = math.min(2 ^ attempt, max_backoff)
    return math.random() * ceil
end

local record Opts
    max_attempts: number
    max_backoff: number
    rate_tokens: number
    retry_cost: number
    timeout_cost: number
    no_retry_increment: number
end

local record Token
    attempt: number
    cost: number
end

function M.new(opts: Opts): table
    opts = opts or {} as Opts
    local max_attempts = opts.max_attempts or M.DEFAULT_MAX_ATTEMPTS
    local max_backoff = opts.max_backoff or M.DEFAULT_MAX_BACKOFF
    local retry_cost = opts.retry_cost or M.DEFAULT_RETRY_COST
    local timeout_cost = opts.timeout_cost or M.DEFAULT_TIMEOUT_COST
    local no_retry_increment = opts.no_retry_increment or M.DEFAULT_NO_RETRY_INCREMENT

    local capacity = opts.rate_tokens or M.DEFAULT_RATE_TOKENS
    local max_capacity = capacity

    local retryer: {string: any} = {}

    retryer.acquire_token = function(_self: table): Token
        return { attempt = 0 }
    end

    retryer.retry_token = function(_self: table, token: Token, err: any): number, any
        token.attempt = token.attempt + 1
        if token.attempt >= max_attempts then
            return nil as number, err
        end
        if not (error_mod as table).is_retryable(err) then
            return nil as number, err
        end

        local cost = (error_mod as table).is_timeout(err) and timeout_cost or retry_cost
        if capacity < cost then
            return nil as number, err
        end
        capacity = capacity - cost
        token.cost = cost

        return backoff_delay(token.attempt, max_backoff)
    end

    retryer.record_success = function(_self: table, token: Token)
        if token.cost then
            capacity = math.min(max_capacity, capacity + token.cost)
        else
            capacity = math.min(max_capacity, capacity + no_retry_increment)
        end
    end

    retryer.available_capacity = function(_self: table): number
        return capacity
    end

    return retryer
end

return M
