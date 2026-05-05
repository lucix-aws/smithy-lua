-- Waiter runtime: polling loop with acceptor matching and exponential backoff.

local record waiter_mod
    record Matcher
        success: boolean
        errorType: string
        output: PathMatcher
        inputOutput: PathMatcher
    end

    record PathMatcher
        path: string
        comparator: string
        expected: string
    end

    record Acceptor
        state: string
        matcher: Matcher
    end

    record WaiterConfig
        acceptors: {Acceptor}
        min_delay: number
        max_delay: number
    end

    record WaitOptions
        max_wait_time: number
    end

    compute_delay: function(attempt: integer, min_delay: number, max_delay: number): number
    wait: function(client: any, operation_fn: string, input: {string:any}, waiter_config: WaiterConfig, options: WaitOptions): any, any
    _eval_path: function(obj: any, path: string): any
    _eval_acceptor: function(acceptor: Acceptor, input: any, output: any, err: any): string
end

local function eval_path(obj: any, path: string): any
    local segments: {string} = {}
    for seg in path:gmatch("[^.]+") do
        segments[#segments + 1] = seg
    end

    local function resolve(val: any, idx: integer): any
        if idx > #segments then return val end
        if type(val) ~= "table" then return nil end

        local seg = segments[idx]
        local field = seg:match("^(.-)%[%]$")
        if field then
            if field ~= "" then
                val = (val as {string:any})[field]
                if type(val) ~= "table" then return nil end
            end
            if idx == #segments then return val end
            local out: {any} = {}
            for _, item in ipairs(val as {any}) do
                local r = resolve(item, idx + 1)
                if r ~= nil then
                    if type(r) == "table" and idx + 1 <= #segments and segments[idx + 1]:find("%[%]$") then
                        for _, v in ipairs(r as {any}) do out[#out + 1] = v end
                    else
                        out[#out + 1] = r
                    end
                end
            end
            return out
        else
            return resolve((val as {string:any})[seg], idx + 1)
        end
    end

    return resolve(obj, 1)
end

local function match_comparator(comparator: string, value: any, expected: string): boolean
    if comparator == "stringEquals" then
        return tostring(value) == expected
    elseif comparator == "booleanEquals" then
        return tostring(value) == expected
    elseif comparator == "allStringEquals" then
        if type(value) ~= "table" or #(value as {any}) == 0 then return false end
        for _, v in ipairs(value as {any}) do
            if tostring(v) ~= expected then return false end
        end
        return true
    elseif comparator == "anyStringEquals" then
        if type(value) ~= "table" then return false end
        for _, v in ipairs(value as {any}) do
            if tostring(v) == expected then return true end
        end
        return false
    end
    return false
end

local function eval_acceptor(acceptor: waiter_mod.Acceptor, input: any, output: any, err: any): string
    local matcher = acceptor.matcher

    if matcher.success ~= nil then
        if matcher.success == true and not err then return acceptor.state end
        if matcher.success == false and err then return acceptor.state end
        return nil
    end

    if matcher.errorType then
        if err and (err as {string:any}).code == matcher.errorType then return acceptor.state end
        return nil
    end

    if err then return nil end

    if matcher.output then
        local val = eval_path(output, matcher.output.path)
        if match_comparator(matcher.output.comparator, val, matcher.output.expected) then
            return acceptor.state
        end
        return nil
    end

    if matcher.inputOutput then
        local synthetic: {string:any} = { input = input, output = output }
        local val = eval_path(synthetic, matcher.inputOutput.path)
        if match_comparator(matcher.inputOutput.comparator, val, matcher.inputOutput.expected) then
            return acceptor.state
        end
        return nil
    end

    return nil
end

function waiter_mod.compute_delay(attempt: integer, min_delay: number, max_delay: number): number
    if attempt <= 1 then return min_delay end
    local delay = min_delay * (2 ^ (attempt - 1))
    if delay > max_delay then delay = max_delay end
    if delay > min_delay then
        delay = min_delay + math.random() * (delay - min_delay)
    end
    return delay
end

local function sleep(seconds: number)
    local ok, socket = pcall(require, "socket") as (boolean, any)
    if ok and (socket as {string:any}).sleep then
        local sleep_fn = (socket as {string:any}).sleep as function(number)
        sleep_fn(seconds)
    else
        local target = os.clock() + seconds
        while os.clock() < target do end
    end
end

function waiter_mod.wait(client: any, operation_fn: string, input: {string:any}, waiter_config: waiter_mod.WaiterConfig, options: waiter_mod.WaitOptions): any, any
    options = options or {} as waiter_mod.WaitOptions
    local max_wait = options.max_wait_time
    if not max_wait or max_wait <= 0 then
        return nil, { type = "sdk", code = "WaiterInvalidConfig", message = "max_wait_time is required and must be > 0" }
    end

    local min_delay = waiter_config.min_delay or 2
    local max_delay = waiter_config.max_delay or 120
    local acceptors = waiter_config.acceptors

    local remaining = max_wait
    local attempt = 0

    while true do
        attempt = attempt + 1
        local start = os.clock()

        local op_fn = (client as {string:any})[operation_fn] as function(any, {string:any}): any, any
        local output, err = op_fn(client, input)

        local state: string
        for _, acceptor in ipairs(acceptors) do
            state = eval_acceptor(acceptor, input, output, err)
            if state then break end
        end

        if state == "success" then
            return output, nil
        elseif state == "failure" then
            local msg = "waiter state transitioned to Failure"
            if err then msg = msg .. ": " .. ((err as {string:any}).message or (err as {string:any}).code or "") as string end
            return nil, { type = "sdk", code = "WaiterFailure", message = msg }
        end

        if not state and err then
            return nil, err
        end

        local elapsed = os.clock() - start
        remaining = remaining - elapsed

        if remaining <= min_delay then
            return nil, { type = "sdk", code = "WaiterTimeout", message = "exceeded max wait time" }
        end

        local delay = waiter_mod.compute_delay(attempt, min_delay, max_delay)
        if remaining - delay < min_delay then
            delay = remaining - min_delay
        end

        sleep(delay)
        remaining = remaining - delay
    end
end

waiter_mod._eval_path = eval_path
waiter_mod._eval_acceptor = eval_acceptor

return waiter_mod
