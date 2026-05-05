-- smithy-lua runtime: operation interceptors
--
-- Interceptors allow injecting code into the request execution pipeline.
-- An interceptor is a table with optional hook functions. Hooks are either
-- "read" (observe-only) or "modify" (can return a new value).
--
-- Hook execution order:
--   read_before_execution(context)
--   modify_before_serialization(context) -> input
--   read_before_serialization(context)
--   [serialize]
--   read_after_serialization(context)
--   modify_before_retry_loop(context) -> request
--   [retry loop]:
--     read_before_attempt(context)
--     modify_before_signing(context) -> request
--     read_before_signing(context)
--     [sign]
--     read_after_signing(context)
--     modify_before_transmit(context) -> request
--     read_before_transmit(context)
--     [transmit]
--     read_after_transmit(context)
--     modify_before_deserialization(context) -> response
--     read_before_deserialization(context)
--     [deserialize]
--     read_after_deserialization(context)
--     modify_before_attempt_completion(context) -> output, err
--     read_after_attempt(context)
--   [end retry loop]
--   modify_before_completion(context) -> output, err
--   read_after_execution(context)

local M = {}

--- Run a "read" hook across all interceptors. Errors are captured; the last
--- error wins (earlier errors are dropped per SRA spec).
--- Returns nil on success, or the last error raised.
local function run_read(interceptors, hook_name, context)
    local last_err
    for i = 1, #interceptors do
        local hook = interceptors[i][hook_name]
        if hook then
            local ok, err = pcall(hook, interceptors[i], context)
            if not ok then
                last_err = err
            end
        end
    end
    return last_err
end

--- Run a "modify" hook that returns a single value (input, request, or response).
--- Each interceptor receives the updated context. Returns the final value and
--- nil on success, or nil and an error if a hook raises.
local function run_modify(interceptors, hook_name, context, field)
    local value = context[field]
    for i = 1, #interceptors do
        local hook = interceptors[i][hook_name]
        if hook then
            local ok, result = pcall(hook, interceptors[i], context)
            if not ok then
                return nil, result
            end
            if result ~= nil then
                value = result
                context[field] = value
            end
        end
    end
    return value, nil
end

--- Run modify_before_attempt_completion or modify_before_completion.
--- These hooks receive (context, err) and return (output, err).
--- They can swallow errors by returning output without error, or replace errors.
local function run_modify_completion(interceptors, hook_name, context, current_err)
    local output = context.output
    local err = current_err
    for i = 1, #interceptors do
        local hook = interceptors[i][hook_name]
        if hook then
            local ok, new_output, new_err = pcall(hook, interceptors[i], context, err)
            if not ok then
                err = new_output -- pcall puts the error in the second return
                output = nil
            else
                output = new_output
                err = new_err
                context.output = output
            end
        end
    end
    return output, err
end

--- Run a read hook that also receives the current error (readAfterAttempt, readAfterExecution).
local function run_read_with_error(interceptors, hook_name, context, current_err)
    local err = current_err
    for i = 1, #interceptors do
        local hook = interceptors[i][hook_name]
        if hook then
            local ok, new_err = pcall(hook, interceptors[i], context, err)
            if not ok then
                err = new_err
            end
        end
    end
    return err
end

M.run_read = run_read
M.run_modify = run_modify
M.run_modify_completion = run_modify_completion
M.run_read_with_error = run_read_with_error

return M
