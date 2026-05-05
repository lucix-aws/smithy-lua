-- LuaJIT bit library declarations
local record bit
    band: function(integer, integer, ...: integer): integer
    bor: function(integer, integer, ...: integer): integer
    bxor: function(integer, integer, ...: integer): integer
    bnot: function(integer): integer
    lshift: function(integer, integer): integer
    rshift: function(integer, integer): integer
    arshift: function(integer, integer): integer
    rol: function(integer, integer): integer
    ror: function(integer, integer): integer
    tobit: function(number): integer
    tohex: function(integer, integer): string
    bswap: function(integer): integer
end

return bit
