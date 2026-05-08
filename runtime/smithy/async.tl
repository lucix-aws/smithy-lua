-- smithy.async - Operation-based async with curl_multi event loop

local ffi = require("ffi")

pcall(ffi.cdef, [[
typedef void CURL;
typedef void CURLM;
typedef int CURLcode;
typedef int CURLMcode;
typedef int CURLMSG;

struct CURLMsg {
    CURLMSG msg;
    CURL *easy_handle;
    union {
        void *whatever;
        CURLcode result;
    } data;
};

CURLM *curl_multi_init(void);
CURLMcode curl_multi_cleanup(CURLM *multi);
CURLMcode curl_multi_add_handle(CURLM *multi, CURL *easy);
CURLMcode curl_multi_remove_handle(CURLM *multi, CURL *easy);
CURLMcode curl_multi_perform(CURLM *multi, int *running_handles);
CURLMcode curl_multi_wait(CURLM *multi, void *extra_fds, unsigned int extra_nfds,
                          int timeout_ms, int *numfds);
struct CURLMsg *curl_multi_info_read(CURLM *multi, int *msgs_in_queue);

CURL *curl_easy_init(void);
void curl_easy_cleanup(CURL *handle);
CURLcode curl_easy_setopt(CURL *handle, int option, ...);
CURLcode curl_easy_getinfo(CURL *handle, int info, ...);

struct curl_slist;
struct curl_slist *curl_slist_append(struct curl_slist *list, const char *string);
void curl_slist_free_all(struct curl_slist *list);
]])

local curl = ffi.load("curl")
local CURLMSG_DONE = 1

local record M
    record Operation
        _resolved: boolean
        _value: any
        _err: any
        _waiters: {thread}

        resolve: function(Operation, value: any, err: any)
        await: function(Operation): any, any
    end

    record Loop
        _multi: ffi.CData
        _handles: {string: LoopEntry}
        _readers: {thread}
        _running: ffi.CData
        _numfds: ffi.CData
        _msgs: ffi.CData

        add: function(Loop, easy_handle: ffi.CData, cleanup_fn: function(ffi.CData): any, any): Operation
        poll: function(Loop)
        run_until: function(Loop, op: Operation)
        run_until_all: function(Loop, ops: {Operation})
        close: function(Loop)
        yield_for_data: function(Loop)
    end

    record LoopEntry
        op: Operation
        cleanup: function(ffi.CData): any, any
        handle: ffi.CData
    end

    new_operation: function(): Operation
    new_loop: function(): Loop
    get_loop: function(): Loop
    await_all: function(ops: {Operation}): {{any}}
end

local Operation: metatable<M.Operation> = { __index = {} as M.Operation }
local op_index = Operation.__index as M.Operation

function M.new_operation(): M.Operation
    return setmetatable({
        _resolved = false,
        _value = nil,
        _err = nil,
        _waiters = nil,
    } as M.Operation, Operation)
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
        local loop = M.get_loop()
        loop:run_until(self)
        return self._value, self._err
    else
        if not self._waiters then self._waiters = {} end
        self._waiters[#self._waiters + 1] = co
        return coroutine.yield()
    end
end

---------------------------------------------------------------------------
-- await_all
---------------------------------------------------------------------------
function M.await_all(ops: {M.Operation}): {{any}}
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
        local loop = M.get_loop()
        loop:run_until_all(ops)
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

---------------------------------------------------------------------------
-- Event Loop
---------------------------------------------------------------------------
local Loop: metatable<M.Loop> = { __index = {} as M.Loop }
local loop_index = Loop.__index as M.Loop

local _loop: M.Loop = nil

function M.new_loop(): M.Loop
    local multi = curl.curl_multi_init() as ffi.CData
    if multi == nil then
        error("curl_multi_init failed")
    end
    return setmetatable({
        _multi = multi,
        _handles = {},
        _readers = {},
        _running = ffi.new("int[1]"),
        _numfds = ffi.new("int[1]"),
        _msgs = ffi.new("int[1]"),
    } as M.Loop, Loop)
end

function loop_index:add(easy_handle: ffi.CData, cleanup_fn: function(ffi.CData): any, any): M.Operation
    local op = M.new_operation()
    local key = tostring(easy_handle)
    self._handles[key] = { op = op, cleanup = cleanup_fn, handle = easy_handle }
    curl.curl_multi_add_handle(self._multi, easy_handle)
    return op
end

function loop_index:poll()
    curl.curl_multi_perform(self._multi, self._running)
    local readers = self._readers
    if #readers > 0 then
        self._readers = {}
        for _, co in ipairs(readers) do
            if coroutine.status(co) == "suspended" then
                coroutine.resume(co)
            end
        end
    end
    while true do
        local msg = curl.curl_multi_info_read(self._multi, self._msgs) as any
        if msg == nil then break end
        local msg_tbl = msg as {string:any}
        if (msg_tbl.msg as integer) == CURLMSG_DONE then
            local key = tostring(msg_tbl.easy_handle)
            local entry = self._handles[key]
            if entry then
                self._handles[key] = nil
                curl.curl_multi_remove_handle(self._multi, msg_tbl.easy_handle as ffi.CData)
                local value, err = entry.cleanup(msg_tbl.data as ffi.CData)
                entry.op:resolve(value, err)
            end
        end
    end
end

function loop_index:run_until(op: M.Operation)
    while not op._resolved do
        self:poll()
        if not op._resolved and ((self._running as any)[0] > 0 or #self._readers > 0) then
            curl.curl_multi_wait(self._multi, nil, 0, 100, self._numfds)
        end
    end
end

function loop_index:run_until_all(ops: {M.Operation})
    while true do
        local all_done = true
        for _, op in ipairs(ops) do
            if not op._resolved then all_done = false; break end
        end
        if all_done then return end
        self:poll()
        if (self._running as any)[0] > 0 or #self._readers > 0 then
            curl.curl_multi_wait(self._multi, nil, 0, 100, self._numfds)
        end
    end
end

function loop_index:close()
    if self._multi ~= nil then
        curl.curl_multi_cleanup(self._multi)
        self._multi = nil
    end
end

function loop_index:yield_for_data()
    local co = coroutine.running()
    if not co then
        self:poll()
        if (self._running as any)[0] > 0 then
            curl.curl_multi_wait(self._multi, nil, 0, 100, self._numfds)
        end
        return
    end
    self._readers[#self._readers + 1] = co
    coroutine.yield()
end

---------------------------------------------------------------------------
-- Singleton
---------------------------------------------------------------------------
function M.get_loop(): M.Loop
    if not _loop then
        _loop = M.new_loop()
    end
    return _loop
end

return M
