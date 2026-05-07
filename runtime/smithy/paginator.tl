-- Paginator runtime: returns an iterator over pages from a @paginated operation.

local record M
    record PaginatorConfig
        input_token: string
        output_token: string
        items: string
        page_size: string
    end

    pages: function(client: any, op_name: string, input: {string:any}, config: PaginatorConfig): function(): {string:any}, any
    items: function(client: any, op_name: string, input: {string:any}, config: PaginatorConfig): function(): any
    _get_path: function(obj: any, path: string): any
end

local function get_path(obj: any, path: string): any
    local val: any = obj
    for seg in path:gmatch("[^.]+") do
        if type(val) ~= "table" then return nil end
        val = (val as {string:any})[seg]
    end
    return val
end

local function shallow_copy(t: {string:any}): {string:any}
    local out: {string:any} = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

function M.pages(client: any, op_name: string, input: {string:any}, config: M.PaginatorConfig): function(): {string:any}, any
    local done = false
    local prev_token: string = nil

    return function(): {string:any}, any
        if done then return nil end

        local cl = client as {string:any}
        local op_fn = cl[op_name] as function(any, any): any, any
        local output, err = op_fn(client, input)
        if err then
            done = true
            return nil, err
        end

        local next_token = get_path(output, config.output_token) as string

        if next_token == nil or next_token == "" or next_token == prev_token then
            done = true
        else
            prev_token = next_token
            input = shallow_copy(input)
            input[config.input_token] = next_token
        end

        return output as {string:any}, nil
    end
end

function M.items(client: any, op_name: string, input: {string:any}, config: M.PaginatorConfig): function(): any
    if not config.items then
        error("paginator.items() requires config.items to be set")
    end

    local page_iter = M.pages(client, op_name, input, config)
    local current_items: {any} = nil
    local idx = 0

    return function(): any
        while true do
            if current_items and idx < #current_items then
                idx = idx + 1
                return current_items[idx]
            end

            local output, err = page_iter()
            if output == nil then
                if err then
                    local e = err as {string:any}
                    error((e.message or e.code or "pagination error") as string)
                end
                return nil
            end

            current_items = get_path(output, config.items) as {any}
            idx = 0

            if type(current_items) ~= "table" then
                current_items = nil
            end
        end
    end
end

M._get_path = get_path

return M
