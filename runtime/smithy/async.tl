-- smithy.async - Operation (future/promise) and await primitives
--
-- An Operation<T> represents a value of type T that may not be available yet.
-- Operations can be awaited individually or in batch.

local record M
    record Operation<T>
        _resolved: boolean
        _value: T
        _err: any
        _waiters: {thread}

        resolve: function(Operation<T>, value: T, err: any)
        await: function(Operation<T>): T, any
    end

    new_operation: function<T>(): Operation<T>
    await_all: function<T>(ops: {Operation<T>}): {{any}}
    set_driver: function(driver: function())
end

local Operation_mt: metatable<M.Operation<any>> = { __index = {} as M.Operation<any> }
local op_index = Operation_mt.__index as M.Operation<any>

local _driver: function() = nil

function M.set_driver(driver: function())
    _driver = driver
end

function M.new_operation<T>(): M.Operation<T>
    return setmetatable({
        _resolved = false,
        _value = nil,
        _err = nil,
        _waiters = nil,
    } as M.Operation<T>, Operation_mt as metatable<M.Operation<T>>)
end

function op_index:resolve(value: any, err: any)
    if self._resolved then return end
    self._resolved = true
    self._value = value
    self._err = err
    if self._waiters then
        for _, co in ipairs(self._waiters) do
            coroutine.resume(co, value, err)
        end
        self._waiters = nil
    end
end

function op_index:await(): any, any
    if self._resolved then
        return self._value, self._err
    end
    local co, is_main = coroutine.running()
    if is_main or not co then
        while not self._resolved do
            if _driver then
                _driver()
            end
        end
        return self._value, self._err
    else
        if not self._waiters then self._waiters = {} end
        self._waiters[#self._waiters + 1] = co
        return coroutine.yield()
    end
end

function M.await_all<T>(ops: {M.Operation<T>}): {{any}}
    local results: {{any}} = {}
    local pending: {integer} = {}
    for i, op in ipairs(ops) do
        if op._resolved then
            results[i] = { op._value, op._err }
        else
            pending[#pending + 1] = i
        end
    end
    if #pending == 0 then return results end

    local co, is_main = coroutine.running()
    if is_main or not co then
        while true do
            local all_done = true
            for _, i in ipairs(pending) do
                if not ops[i]._resolved then all_done = false; break end
            end
            if all_done then break end
            if _driver then
                _driver()
            end
        end
        for i, op in ipairs(ops) do
            results[i] = { op._value, op._err }
        end
    else
        for _, i in ipairs(pending) do
            local op = ops[i]
            if not op._waiters then op._waiters = {} end
            op._waiters[#op._waiters + 1] = co
        end
        local remaining = #pending
        while remaining > 0 do
            coroutine.yield()
            remaining = 0
            for _, i in ipairs(pending) do
                if not ops[i]._resolved then remaining = remaining + 1 end
            end
        end
        for i, op in ipairs(ops) do
            results[i] = { op._value, op._err }
        end
    end
    return results
end

return M
