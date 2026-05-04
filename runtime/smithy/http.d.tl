-- Teal declarations for smithy-lua runtime/http

local record M

    record Request
        method: string
        url: string
        headers: {string: string}
        body: function(): string, string
    end

    record Response
        status_code: integer
        headers: {string: string}
        body: function(): string, string
    end

    string_reader: function(s: string): function(): string, string
    read_all: function(reader: function(): string, string): string, string
    new_request: function(method: string, url: string, headers: {string: string}, body: function(): string, string): Request

end

return M
