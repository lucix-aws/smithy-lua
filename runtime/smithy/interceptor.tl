-- smithy-lua runtime: operation interceptors

local record M
    run_read: function(interceptors: {any}, hook_name: string, context: {string:any}): any
    run_modify: function(interceptors: {any}, hook_name: string, context: {string:any}, field: string): any, any
    run_modify_completion: function(interceptors: {any}, hook_name: string, context: {string:any}, err: any): any, any
    run_read_with_error: function(interceptors: {any}, hook_name: string, context: {string:any}, err: any): any
end

local function run_read(interceptors: {any}, hook_name: string, context: {string:any}): any
    local last_err: any
    for i = 1, #interceptors do
        local ic = interceptors[i] as {string:any}
        local hook = ic[hook_name] as function(any, any)
        if hook then
            local ok, err = pcall(hook, interceptors[i], context)
            if not ok then
                last_err = err
            end
        end
    end
    return last_err
end

local function run_modify(interceptors: {any}, hook_name: string, context: {string:any}, field_name: string): any, any
    local value: any = context[field_name]
    for i = 1, #interceptors do
        local ic = interceptors[i] as {string:any}
        local hook = ic[hook_name] as function(any, any): any
        if hook then
            local ok, result = pcall(hook, interceptors[i], context)
            if not ok then
                return nil, result
            end
            if result ~= nil then
                value = result
                context[field_name] = value
            end
        end
    end
    return value, nil
end

local function run_modify_completion(interceptors: {any}, hook_name: string, context: {string:any}, current_err: any): any, any
    local output: any = context.output
    local err: any = current_err
    for i = 1, #interceptors do
        local ic = interceptors[i] as {string:any}
        local hook = ic[hook_name] as function(any, any, any): any, any
        if hook then
            local ok, new_output, new_err = pcall(hook, interceptors[i], context, err)
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

local function run_read_with_error(interceptors: {any}, hook_name: string, context: {string:any}, current_err: any): any
    local err: any = current_err
    for i = 1, #interceptors do
        local ic = interceptors[i] as {string:any}
        local hook = ic[hook_name] as function(any, any, any)
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
