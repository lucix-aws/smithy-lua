local module = {}

module.Header = {}

function module.Header:New()
    local t = {
        _values = {},
    }
    setmetatable(t, self)
    self.__index = self
    return t
end

function module.Header:Get(k)
    return self._values[k]
end

function module.Header:Set(k, v)
    self._values[k] = v
end

module.Request = {}

function module.Request:New()
    local t = {
        Method = '',
        Header = module.Header:New(),
        Body   = nil,
    }
    setmetatable(t, self)
    self.__index = self
    return t
end

return module
