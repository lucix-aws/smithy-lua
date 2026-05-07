-- Type declarations for LuaJIT bit library
local record bit
    tobit: function(x: number): number
    tohex: function(x: number, n?: number): string
    bnot: function(x: number): number
    band: function(x: number, ...: number): number
    bor: function(x: number, ...: number): number
    bxor: function(x: number, ...: number): number
    lshift: function(x: number, n: number): number
    rshift: function(x: number, n: number): number
    arshift: function(x: number, n: number): number
    rol: function(x: number, n: number): number
    ror: function(x: number, n: number): number
    bswap: function(x: number): number
end

return bit
