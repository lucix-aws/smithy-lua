-- Type declarations for LuaJIT jit module
local record jit
    off: function(fn?: any)
    on: function(fn?: any)
    flush: function(fn?: any)
    status: function(): boolean
    version: string
    version_num: integer
    os: string
    arch: string
end

return jit
