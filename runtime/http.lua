local module = {}

module.Header = {}

function module.Header.New()
    return setmetatable({
        _values = {},
    }, { __index = module.Header })
end

function module.Header:Get(k)
    return self._values[k]
end

function module.Header:Set(k, v)
    self._values[k] = v
end

module.Request = {}

function module.Request.New()
    return setmetatable({
        URL    = nil,
        Host   = nil,
        Method = nil,
        Header = module.Header.New(),
        Body   = nil,
    }, { __index = module.Request })
end

return module
