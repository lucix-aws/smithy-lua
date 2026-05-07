-- Pure Lua 256-bit unsigned integer arithmetic for LuaJIT

local record M
    type BigInt = {number}
    zero: function(): BigInt
    from_int: function(n: number): BigInt
    from_bytes: function(s: string): BigInt
    to_bytes: function(a: BigInt): string
    to_hex: function(a: BigInt): string
    from_hex: function(h: string): BigInt
    cmp: function(a: BigInt, b: BigInt): number
    add: function(a: BigInt, b: BigInt): BigInt, number
    sub: function(a: BigInt, b: BigInt): BigInt, number
    is_zero: function(a: BigInt): boolean
    copy: function(a: BigInt): BigInt
end

local LIMBS = 10
local BASE = 0x4000000

function M.zero(): M.BigInt
    return {0,0,0,0,0,0,0,0,0,0}
end

function M.from_int(n: number): M.BigInt
    local r = M.zero()
    r[1] = n % BASE
    r[2] = math.floor(n / BASE) % BASE
    return r
end

function M.from_bytes(s: string): M.BigInt
    assert(#s == 32, "from_bytes expects 32 bytes")
    local r = M.zero()
    local bits = 0
    local acc = 0
    local li = 1
    for i = 32, 1, -1 do
        acc = acc + string.byte(s, i) * (2 ^ bits)
        bits = bits + 8
        while bits >= 26 and li <= LIMBS do
            r[li] = acc % BASE
            acc = math.floor(acc / BASE)
            bits = bits - 26
            li = li + 1
        end
    end
    if li <= LIMBS then r[li] = acc end
    return r
end

function M.to_bytes(a: M.BigInt): string
    local bytes: {number} = {}
    local acc = 0
    local bits = 0
    local li = 1
    for _ = 1, 32 do
        while bits < 8 and li <= LIMBS do
            acc = acc + a[li] * (2 ^ bits)
            bits = bits + 26
            li = li + 1
        end
        bytes[#bytes + 1] = acc % 256
        acc = math.floor(acc / 256)
        bits = bits - 8
    end
    local out: {string} = {}
    for i = 32, 1, -1 do
        out[#out + 1] = string.char(bytes[i])
    end
    return table.concat(out)
end

function M.to_hex(a: M.BigInt): string
    local s = M.to_bytes(a)
    local h: {string} = {}
    for i = 1, 32 do
        h[i] = string.format("%02X", string.byte(s, i))
    end
    return table.concat(h)
end

function M.from_hex(h: string): M.BigInt
    assert(#h == 64, "from_hex expects 64 hex chars")
    local bytes: {string} = {}
    for i = 1, 64, 2 do
        bytes[#bytes + 1] = string.char(tonumber(h:sub(i, i+1), 16))
    end
    return M.from_bytes(table.concat(bytes))
end

function M.cmp(a: M.BigInt, b: M.BigInt): number
    for i = LIMBS, 1, -1 do
        if a[i] > b[i] then return 1 end
        if a[i] < b[i] then return -1 end
    end
    return 0
end

function M.add(a: M.BigInt, b: M.BigInt): M.BigInt, number
    local r = M.zero()
    local carry = 0
    for i = 1, LIMBS do
        local s = a[i] + b[i] + carry
        r[i] = s % BASE
        carry = math.floor(s / BASE)
    end
    return r, carry
end

function M.sub(a: M.BigInt, b: M.BigInt): M.BigInt, number
    local r = M.zero()
    local borrow = 0
    for i = 1, LIMBS do
        local s = a[i] - b[i] - borrow
        if s < 0 then
            s = s + BASE
            borrow = 1
        else
            borrow = 0
        end
        r[i] = s
    end
    return r, borrow
end

function M.is_zero(a: M.BigInt): boolean
    for i = 1, LIMBS do
        if a[i] ~= 0 then return false end
    end
    return true
end

function M.copy(a: M.BigInt): M.BigInt
    return {a[1],a[2],a[3],a[4],a[5],a[6],a[7],a[8],a[9],a[10]}
end

return M
