-- Teal declarations for smithy-lua runtime/crypto/hmac

local record M
    digest: function(key: string, msg: string): string
    hex_digest: function(key: string, msg: string): string
end

return M
