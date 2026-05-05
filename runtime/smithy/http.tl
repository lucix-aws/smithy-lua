-- smithy-lua runtime: HTTP types and helpers

local record http_mod
    type Reader = function(): string, string

    record Request
        method: string
        url: string
        headers: {string:string}
        body: Reader
        _path: string
    end

    record Response
        status_code: integer
        headers: {string:string}
        body: Reader
        close: function()
    end

    type HttpClient = function(Request): Response, any
end

function http_mod.string_reader(s: string): http_mod.Reader
    local done = false
    return function(): string, string
        if done then return nil end
        done = true
        return s
    end
end

function http_mod.read_all(reader: http_mod.Reader): string, string
    local chunks: {string} = {}
    while true do
        local chunk, err = reader()
        if err then return nil, err end
        if not chunk then break end
        chunks[#chunks + 1] = chunk
    end
    return table.concat(chunks)
end

function http_mod.new_request(method: string, url: string, headers: {string:string}, body: http_mod.Reader): http_mod.Request
    return {
        method = method or "GET",
        url = url or "",
        headers = headers or {},
        body = body,
    }
end

return http_mod
