local module = {}

function module.StrToHex(str)
    local hex = ''
    for i=1,#str do
        hex = hex .. string.format("%02x", string.byte(str, i))
    end
    return hex
end

function module.Join(strs, delim)
    local joined = ''
    for i=1,#strs do
        joined = joined .. strs[i]
        if i < #strs then
            joined = joined .. delim
        end
    end
    return joined
end

function module.StartsWith(str, prefix)
    return str:sub(1, #prefix) == prefix
end

return module