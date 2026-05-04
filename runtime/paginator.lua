-- Paginator runtime: returns an iterator over pages from a @paginated operation.
-- Codegen emits per-operation config; this module provides the generic engine.

local M = {}

--- Resolve a dot-path (e.g. "result.nextToken") against a table.
local function get_path(obj, path)
    local val = obj
    for seg in path:gmatch("[^.]+") do
        if type(val) ~= "table" then return nil end
        val = val[seg]
    end
    return val
end

--- Set a value at a top-level key on a (shallow-copied) table.
local function shallow_copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

--- Returns an iterator function that yields (output, err) per page.
--- Usage: for output, err in paginator.pages(client, "listFoos", input, config) do ... end
--- config = { input_token = "NextToken", output_token = "NextToken", items = "Items" }
function M.pages(client, op_name, input, config)
    local done = false
    local prev_token = nil

    return function()
        if done then return nil end

        local output, err = client[op_name](client, input)
        if err then
            done = true
            return nil, err
        end

        local next_token = get_path(output, config.output_token)

        -- Stop: nil/empty token or same token repeated
        if next_token == nil or next_token == "" or next_token == prev_token then
            done = true
        else
            prev_token = next_token
            input = shallow_copy(input)
            input[config.input_token] = next_token
        end

        return output, nil
    end
end

--- Returns an iterator that yields individual items across all pages.
--- Only works when config.items is set.
--- Usage: for item in paginator.items(client, "listFoos", input, config) do ... end
function M.items(client, op_name, input, config)
    if not config.items then
        error("paginator.items() requires config.items to be set")
    end

    local page_iter = M.pages(client, op_name, input, config)
    local current_items = nil
    local idx = 0

    return function()
        while true do
            if current_items and idx < #current_items then
                idx = idx + 1
                return current_items[idx]
            end

            local output, err = page_iter()
            if output == nil then
                if err then error(err.message or err.code or "pagination error") end
                return nil
            end

            current_items = get_path(output, config.items)
            idx = 0

            if type(current_items) ~= "table" then
                current_items = nil
            end
        end
    end
end

M._get_path = get_path

return M
