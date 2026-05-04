-- Teal declarations for smithy-lua runtime/crypto/sha256

local record M
    digest: function(msg: string): string
    hex_digest: function(msg: string): string
end

return M
