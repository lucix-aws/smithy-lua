-- smithy-lua runtime: HTTP types and helpers

local record M
    type Reader = function(): string, M.Error
    type HttpClient = function(request: M.Request): M.Response, M.Error

    record Error
        type: string
        code: string
        message: string
        status_code: integer
    end

    record Request
        method: string
        url: string
        headers: {string:string}
        body: Reader
    end

    record Response
        status_code: integer
        headers: {string:string}
        body: Reader
    end
end

function M.string_reader(s: string): M.Reader
    local done = false
    return function(): string, M.Error
        if done then return nil end
        done = true
        return s
    end
end

function M.read_all(reader: M.Reader): string, M.Error
    local chunks: {string} = {}
    while true do
        local chunk, err = reader()
        if err then return nil, err end
        if not chunk then break end
        chunks[#chunks + 1] = chunk
    end
    return table.concat(chunks)
end

function M.new_request(method: string, url: string, headers: {string:string}, body: M.Reader): M.Request
    return {
        method = method or "GET",
        url = url or "",
        headers = headers or {},
        body = body,
    }
end

return M
