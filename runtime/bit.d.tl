-- Type declarations for LuaJIT bit library
local record bit
    tobit: function(x: number): integer
    tohex: function(x: number, n?: number): string
    bnot: function(x: number): integer
    band: function(x: number, ...: number): integer
    bor: function(x: number, ...: number): integer
    bxor: function(x: number, ...: number): integer
    lshift: function(x: number, n: number): integer
    rshift: function(x: number, n: number): integer
    arshift: function(x: number, n: number): integer
    rol: function(x: number, n: number): integer
    ror: function(x: number, n: number): integer
    bswap: function(x: number): integer
end

return bit
