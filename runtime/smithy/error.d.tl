-- Teal declarations for runtime/error.lua

local record M

    -- Error categories
    API: string
    HTTP: string
    SDK: string

    record Error
        type: string
        code: string
        message: string
        status_code: integer
        -- API errors may carry additional deserialized fields
        {string: any}
    end

    new_api_error: function(code: string, message: string, status_code: integer, extra: {string: any}): Error
    new_http_error: function(message: string): Error
    new_sdk_error: function(code: string, message: string): Error

    is_throttle: function(err: Error): boolean
    is_transient: function(err: Error): boolean
    is_timeout: function(err: Error): boolean
    is_retryable: function(err: Error): boolean
end

return M
