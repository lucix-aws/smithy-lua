-- smithy-lua runtime: operation interceptors

local http_mod = require("smithy.http")

local record interceptor_mod
    record Context
        input: any
        output: any
        request: http_mod.Request
        response: http_mod.Response
        operation: any
    end

    type Interceptor = {string:any}
end

function interceptor_mod.run_read(interceptors: {interceptor_mod.Interceptor}, hook_name: string, context: interceptor_mod.Context): any
    local last_err: any = nil
    for i = 1, #interceptors do
        local hook = (interceptors[i] as {string:any})[hook_name] as function(any, interceptor_mod.Context)
        if hook then
            local ok, err_val = pcall(hook, interceptors[i], context) as (boolean, any)
            if not ok then
                last_err = err_val
            end
        end
    end
    return last_err
end

function interceptor_mod.run_modify(interceptors: {interceptor_mod.Interceptor}, hook_name: string, context: interceptor_mod.Context, field: string): any, any
    local value = (context as {string:any})[field]
    for i = 1, #interceptors do
        local hook = (interceptors[i] as {string:any})[hook_name] as function(any, interceptor_mod.Context): any
        if hook then
            local ok, result = pcall(hook, interceptors[i], context) as (boolean, any)
            if not ok then
                return nil, result
            end
            if result ~= nil then
                value = result;
                (context as {string:any})[field] = value
            end
        end
    end
    return value, nil
end

function interceptor_mod.run_modify_completion(interceptors: {interceptor_mod.Interceptor}, hook_name: string, context: interceptor_mod.Context, current_err: any): any, any
    local output = context.output
    local err: any = current_err
    for i = 1, #interceptors do
        local hook = (interceptors[i] as {string:any})[hook_name] as function(any, interceptor_mod.Context, any): any, any
        if hook then
            local ok, new_output, new_err = pcall(hook, interceptors[i], context, err) as (boolean, any, any)
            if not ok then
                err = new_output
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

function interceptor_mod.run_read_with_error(interceptors: {interceptor_mod.Interceptor}, hook_name: string, context: interceptor_mod.Context, current_err: any): any
    local err: any = current_err
    for i = 1, #interceptors do
        local hook = (interceptors[i] as {string:any})[hook_name] as function(any, interceptor_mod.Context, any)
        if hook then
            local ok, new_err_val = pcall(hook, interceptors[i], context, err) as (boolean, any)
            if not ok then
                err = new_err_val
            end
        end
    end
    return err
end

return interceptor_mod
