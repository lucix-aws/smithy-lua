-- smithy-lua runtime: HTTP types and helpers
-- See CONSTITUTION.md § HTTP Client Interface

local M = {}

--- Create a reader from a string.
function M.string_reader(s)
    local done = false
    return function()
        if done then return nil end
        done = true
        return s
    end
end

--- Read all chunks from a reader into a single string.
function M.read_all(reader)
    local chunks = {}
    while true do
        local chunk, err = reader()
        if err then return nil, err end
        if not chunk then break end
        chunks[#chunks + 1] = chunk
    end
    return table.concat(chunks)
end

--- Create a new HTTP request.
function M.new_request(method, url, headers, body)
    return {
        method = method or "GET",
        url = url or "",
        headers = headers or {},
        body = body,
    }
end

return M
