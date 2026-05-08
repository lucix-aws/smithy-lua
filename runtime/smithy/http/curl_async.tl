-- smithy.http.curl_async - non-blocking HTTP transport using curl_multi
--
-- Registers easy handles with a shared event loop and returns Operations
-- that resolve once headers arrive. Response bodies stream via yield_for_data.

local async = require("smithy.async")
local ffi = require("ffi")
local http = require("smithy.http")

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

local record CurlLib
    curl_multi_init: function(): ffi.CData
    curl_multi_cleanup: function(ffi.CData): ffi.CData
    curl_multi_add_handle: function(ffi.CData, ffi.CData): ffi.CData
    curl_multi_remove_handle: function(ffi.CData, ffi.CData): ffi.CData
    curl_multi_perform: function(ffi.CData, ffi.CData): ffi.CData
    curl_multi_wait: function(ffi.CData, ffi.CData, integer, integer, ffi.CData): ffi.CData
    curl_multi_info_read: function(ffi.CData, ffi.CData): ffi.CData
    curl_easy_init: function(): ffi.CData
    curl_easy_cleanup: function(ffi.CData)
    curl_easy_setopt: function(ffi.CData, integer, any): ffi.CData
    curl_easy_getinfo: function(ffi.CData, integer, ffi.CData): ffi.CData
    curl_slist_append: function(ffi.CData, string): ffi.CData
    curl_slist_free_all: function(ffi.CData)
end

local curl = ffi.load("curl") as CurlLib

local CURLMSG_DONE = 1
local CURLOPT_URL = 10002
local CURLOPT_CUSTOMREQUEST = 10036
local CURLOPT_HTTPHEADER = 10023
local CURLOPT_POSTFIELDS = 10015
local CURLOPT_POSTFIELDSIZE = 60
local CURLOPT_WRITEFUNCTION = 20011
local CURLOPT_HEADERFUNCTION = 20079
local CURLINFO_RESPONSE_CODE = 0x200002

---------------------------------------------------------------------------
-- Loop (curl_multi event loop)
---------------------------------------------------------------------------
local record LoopEntry
    op: async.Operation<any>
    cleanup: function(ffi.CData): any, any
    handle: ffi.CData
end

local record Loop
    _multi: ffi.CData
    _handles: {string: LoopEntry}
    _readers: {thread}
    _running: ffi.CData
    _numfds: ffi.CData
    _msgs: ffi.CData

    add: function(Loop, easy_handle: ffi.CData, cleanup_fn: function(ffi.CData): any, any): async.Operation<any>
    poll: function(Loop)
    yield_for_data: function(Loop)
end

local Loop_mt: metatable<Loop> = { __index = {} as Loop }
local loop_idx = Loop_mt.__index as Loop

local _loop: Loop = nil

local function new_loop(): Loop
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
    } as Loop, Loop_mt)
end

function loop_idx:add(easy_handle: ffi.CData, cleanup_fn: function(ffi.CData): any, any): async.Operation<any>
    local op = async.new_operation()
    local key = tostring(easy_handle)
    self._handles[key] = { op = op, cleanup = cleanup_fn, handle = easy_handle }
    curl.curl_multi_add_handle(self._multi, easy_handle)
    return op
end

function loop_idx:poll()
    curl.curl_multi_perform(self._multi, self._running)
    -- Resume coroutines waiting for body data
    local readers = self._readers
    if #readers > 0 then
        self._readers = {}
        for _, co in ipairs(readers) do
            if coroutine.status(co) == "suspended" then
                coroutine.resume(co)
            end
        end
    end
    -- Check for completed transfers
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

function loop_idx:yield_for_data()
    local co = coroutine.running()
    if not co then
        -- Main thread: poll once
        self:poll()
        if (self._running[0] as integer) > 0 then
            curl.curl_multi_wait(self._multi, nil, 0, 100, self._numfds)
        end
        return
    end
    self._readers[#self._readers + 1] = co
    coroutine.yield()
end

local function get_loop(): Loop
    if not _loop then
        _loop = new_loop()
        -- Register as the async driver so await() can pump us
        async.set_driver(function()
            _loop:poll()
            if (_loop._running[0] as integer) > 0 or #_loop._readers > 0 then
                curl.curl_multi_wait(_loop._multi, nil, 0, 100, _loop._numfds)
            end
        end)
    end
    return _loop
end

---------------------------------------------------------------------------
-- HTTP Client
---------------------------------------------------------------------------
local record M
    available: function(): boolean
    new: function(): http.HttpClient
end

function M.available(): boolean
    local ok = pcall(ffi.load, "curl")
    return ok
end

function M.new(): http.HttpClient
    local loop = get_loop()

    local function do_request(request: http.Request): async.Operation<http.Response>
        local handle = curl.curl_easy_init() as ffi.CData
        if handle == nil then
            local op = async.new_operation()
            op:resolve(nil, { type = "http", code = "CurlError", message = "curl_easy_init failed" })
            return op
        end

        local chunks: {string} = {}
        local chunk_count = 0
        local resp_headers: {string:string} = {}
        local got_status = false
        local transfer_done = false
        local op = async.new_operation()

        local write_cb = ffi.cast("size_t (*)(char *, size_t, size_t, void *)",
        function(ptr: ffi.CData, size: number, nmemb: number, _: ffi.CData): number
            local len = size * nmemb
            chunk_count = chunk_count + 1
            chunks[chunk_count] = ffi.string(ptr, len)

            if not got_status then
                got_status = true
                local code_buf = ffi.new("long[1]") as ffi.CData
                curl.curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, code_buf)
                local status_code = tonumber(code_buf[0]) as integer

                local chunk_idx = 0
                local function body_reader(): string, http.Error
                    while true do
                        chunk_idx = chunk_idx + 1
                        if chunk_idx <= chunk_count then
                            local c = chunks[chunk_idx]
                            chunks[chunk_idx] = nil
                            return c
                        end
                        if transfer_done then return nil end
                        chunk_idx = chunk_idx - 1
                        loop:yield_for_data()
                    end
                end

                op:resolve({
                    status_code = status_code,
                    headers = resp_headers,
                    body = body_reader,
                } as http.Response, nil)
            end
            return len
        end) as ffi.CData

        local header_cb = ffi.cast("size_t (*)(char *, size_t, size_t, void *)",
        function(ptr: ffi.CData, size: number, nmemb: number, _: ffi.CData): number
            local len = size * nmemb
            local line = ffi.string(ptr, len)
            local k, v = line:match("^([^:]+):%s*(.-)%s*$")
            if k then resp_headers[k:lower()] = v end
            return len
        end) as ffi.CData

        curl.curl_easy_setopt(handle, CURLOPT_URL, request.url)
        curl.curl_easy_setopt(handle, CURLOPT_CUSTOMREQUEST, request.method)
        curl.curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, write_cb)
        curl.curl_easy_setopt(handle, CURLOPT_HEADERFUNCTION, header_cb)

        local slist: ffi.CData = nil
        for k, v in pairs(request.headers or {} as {string:string}) do
            slist = curl.curl_slist_append(slist, k .. ": " .. v) as ffi.CData
        end
        if slist ~= nil then
            curl.curl_easy_setopt(handle, CURLOPT_HTTPHEADER, slist)
        end

        if request.body then
            local body = ""
            local b, err = http.read_all(request.body)
            if err then
                (write_cb as ffi.CData):free();
                (header_cb as ffi.CData):free()
                if slist ~= nil then curl.curl_slist_free_all(slist) end
                curl.curl_easy_cleanup(handle)
                op:resolve(nil, { type = "http", code = "ReadError", message = err.message })
                return op
            end
            body = b or ""
            if #body > 0 then
                curl.curl_easy_setopt(handle, CURLOPT_POSTFIELDS, body)
                local body_len = ffi.cast("long", #body) as ffi.CData
                curl.curl_easy_setopt(handle, CURLOPT_POSTFIELDSIZE, body_len)
            end
        end

        loop:add(handle, function(_: ffi.CData): any, any
            transfer_done = true

            if not got_status then
                local code_buf = ffi.new("long[1]") as ffi.CData
                curl.curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, code_buf)
                local status_code = tonumber(code_buf[0]) as integer
                if status_code == 0 then
                    op:resolve(nil, { type = "http", code = "CurlError", message = "connection failed" })
                else
                    op:resolve({
                        status_code = status_code,
                        headers = resp_headers,
                        body = function(): string, http.Error return nil end,
                    } as http.Response, nil)
                end
            end

            (write_cb as ffi.CData):free();
            (header_cb as ffi.CData):free()
            if slist ~= nil then curl.curl_slist_free_all(slist) end
            curl.curl_easy_cleanup(handle)
            return nil, nil
        end)

        return op
    end
    local jit = require("jit")
    jit.off(do_request)

    return { roundtrip = function(_self: http.HttpClient, req: http.Request): async.Operation<http.Response>
        return do_request(req)
    end } as http.HttpClient
end

return M
