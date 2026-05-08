-- HTTP client using libcurl via LuaJIT FFI (curl_multi for streaming).
-- Conforms to: HttpClient interface (roundtrip method returns Operation)

local async = require("smithy.async")
local ffi = require("ffi")
local http = require("smithy.http")

ffi.cdef[[
typedef void CURL;
typedef void CURLM;
typedef int CURLcode;
typedef int CURLMcode;

CURL *curl_easy_init(void);
void curl_easy_cleanup(CURL *handle);
CURLcode curl_easy_setopt(CURL *handle, int option, ...);
CURLcode curl_easy_getinfo(CURL *handle, int info, ...);
const char *curl_easy_strerror(CURLcode code);

CURLM *curl_multi_init(void);
CURLMcode curl_multi_cleanup(CURLM *multi);
CURLMcode curl_multi_add_handle(CURLM *multi, CURL *easy);
CURLMcode curl_multi_remove_handle(CURLM *multi, CURL *easy);
CURLMcode curl_multi_perform(CURLM *multi, int *running_handles);
CURLMcode curl_multi_wait(CURLM *multi, void *extra_fds, unsigned int extra_nfds,
                          int timeout_ms, int *numfds);

struct curl_slist;
struct curl_slist *curl_slist_append(struct curl_slist *list, const char *string);
void curl_slist_free_all(struct curl_slist *list);
]]

local curl = ffi.load("curl")

-- CURLoption constants
local CURLOPT_URL            = 10002
local CURLOPT_CUSTOMREQUEST  = 10036
local CURLOPT_HTTPHEADER     = 10023
local CURLOPT_POSTFIELDS     = 10015
local CURLOPT_POSTFIELDSIZE  = 60
local CURLOPT_WRITEFUNCTION  = 20011
local CURLOPT_HEADERFUNCTION = 20079
local CURLOPT_READFUNCTION   = 20012
local CURLOPT_UPLOAD         = 46
local CURLOPT_INFILESIZE     = 14

-- CURLINFO constants
local CURLINFO_RESPONSE_CODE = 0x200002

local record M
    available: function(): boolean
    new: function(): http.HttpClient
end

local record StreamingRequest
    method: string
    url: string
    headers: {string:string}
    body: http.Reader
    streaming: boolean
end

function M.available(): boolean
    local ok = pcall(ffi.load, "curl")
    return ok
end

function M.new(): http.HttpClient
    local function do_request(request: StreamingRequest): http.Response, http.Error
        local handle = curl.curl_easy_init() as ffi.CData
        if handle == nil then
            return nil, { type = "http", code = "CurlError", message = "curl_easy_init failed" }
        end

        local multi = curl.curl_multi_init() as ffi.CData
        if multi == nil then
            curl.curl_easy_cleanup(handle)
            return nil, { type = "http", code = "CurlError", message = "curl_multi_init failed" }
        end

        -- Chunks buffer: write callback pushes, body reader pops
        local chunks: {string} = {}
        local chunk_count = 0
        local transfer_done = false
        local resp_headers: {string:string} = {}

        local write_cb = ffi.cast("size_t (*)(char *, size_t, size_t, void *)",
            function(ptr: ffi.CData, size: integer, nmemb: integer, _: ffi.CData): integer
                local len = size * nmemb
                chunk_count = chunk_count + 1
                chunks[chunk_count] = ffi.string(ptr, len)
                return len
            end) as ffi.CData

        local header_cb = ffi.cast("size_t (*)(char *, size_t, size_t, void *)",
            function(ptr: ffi.CData, size: integer, nmemb: integer, _: ffi.CData): integer
                local len = size * nmemb
                local line = ffi.string(ptr, len)
                local k, v = line:match("^([^:]+):%s*(.-)%s*$")
                if k then resp_headers[k:lower()] = v end
                return len
            end) as ffi.CData

        -- Set options
        curl.curl_easy_setopt(handle, CURLOPT_URL, request.url)
        curl.curl_easy_setopt(handle, CURLOPT_CUSTOMREQUEST, request.method)
        curl.curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, write_cb)
        curl.curl_easy_setopt(handle, CURLOPT_HEADERFUNCTION, header_cb)

        -- Headers
        local slist: ffi.CData = nil
        for k, v in pairs(request.headers or {} as {string:string}) do
            slist = curl.curl_slist_append(slist, k .. ": " .. v) as ffi.CData
        end
        if slist ~= nil then
            curl.curl_easy_setopt(handle, CURLOPT_HTTPHEADER, slist)
        end

        -- Body
        local read_cb: ffi.CData = nil
        if request.body and request.streaming then
            -- Streaming upload: pull from body reader via READFUNCTION
            local read_buf = ""
            local read_eof = false

            read_cb = ffi.cast("size_t (*)(char *, size_t, size_t, void *)",
                function(dest: ffi.CData, size: integer, nmemb: integer, _: ffi.CData): integer
                    local max = size * nmemb
                    -- Refill buffer from reader if empty
                    while #read_buf == 0 and not read_eof do
                        local chunk = request.body()
                        if not chunk then
                            read_eof = true
                        else
                            read_buf = chunk
                        end
                    end
                    if #read_buf == 0 then return 0 end
                    local n = math.min(#read_buf, max)
                    ffi.copy(dest, read_buf, n)
                    read_buf = read_buf:sub(n + 1)
                    return n
                end) as ffi.CData

            local one = ffi.cast("long", 1)
            curl.curl_easy_setopt(handle, CURLOPT_UPLOAD, one)
            curl.curl_easy_setopt(handle, CURLOPT_READFUNCTION, read_cb)
            local neg_one = ffi.cast("long", -1)
            curl.curl_easy_setopt(handle, CURLOPT_INFILESIZE, neg_one)
        elseif request.body then
            local body = ""
            local b, err = http.read_all(request.body)
            if err then
                (write_cb as any).free(write_cb)
                (header_cb as any).free(header_cb)
                if slist ~= nil then curl.curl_slist_free_all(slist) end
                curl.curl_multi_cleanup(multi)
                curl.curl_easy_cleanup(handle)
                return nil, { type = "http", code = "ReadError", message = err.message }
            end
            body = b or ""
            if #body > 0 then
                curl.curl_easy_setopt(handle, CURLOPT_POSTFIELDS, body)
                local body_len = ffi.cast("long", #body)
                curl.curl_easy_setopt(handle, CURLOPT_POSTFIELDSIZE, body_len)
            end
        end

        -- Add to multi handle
        curl.curl_multi_add_handle(multi, handle)

        -- Poll until we have response headers (status code available)
        local running = ffi.new("int[1]") as ffi.CData
        local numfds = ffi.new("int[1]") as ffi.CData
        while true do
            curl.curl_multi_perform(multi, running)
            -- Check if we have a status code yet
            local code_buf = ffi.new("long[1]") as ffi.CData
            curl.curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, code_buf)
            if (code_buf as any)[0] ~= 0 then
                break
            end
            -- Transfer finished before we got headers (error case)
            if (running as any)[0] == 0 then
                break
            end
            curl.curl_multi_wait(multi, nil, 0, 1000, numfds)
        end

        -- Get status code
        local code_buf = ffi.new("long[1]") as ffi.CData
        curl.curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, code_buf)
        local status_code = tonumber((code_buf as any)[0]) as integer

        if status_code == 0 then
            (write_cb as any).free(write_cb)
            (header_cb as any).free(header_cb)
            curl.curl_multi_remove_handle(multi, handle)
            curl.curl_multi_cleanup(multi)
            if slist ~= nil then curl.curl_slist_free_all(slist) end
            curl.curl_easy_cleanup(handle)
            return nil, { type = "http", code = "CurlError", message = "connection failed" }
        end

        -- Cleanup function
        local cleaned_up = false
        local function cleanup()
            if cleaned_up then return end
            cleaned_up = true
            -- Drain any remaining transfer
            if not transfer_done then
                transfer_done = true
                while (running as any)[0] > 0 do
                    curl.curl_multi_perform(multi, running)
                    if (running as any)[0] > 0 then
                        curl.curl_multi_wait(multi, nil, 0, 100, numfds)
                    end
                end
            end
            curl.curl_multi_remove_handle(multi, handle)
            curl.curl_multi_cleanup(multi)
            ;(write_cb as any).free(write_cb)
            ;(header_cb as any).free(header_cb)
            if read_cb then (read_cb as any).free(read_cb) end
            if slist ~= nil then curl.curl_slist_free_all(slist) end
            curl.curl_easy_cleanup(handle)
        end

        -- Streaming body reader: polls curl_multi for more data
        local chunk_idx = 1
        local function body_reader(): string, http.Error
            -- Return any buffered chunks first
            if chunk_idx <= chunk_count then
                local c = chunks[chunk_idx]
                chunk_idx = chunk_idx + 1
                return c
            end

            -- Transfer already done
            if transfer_done then
                return nil
            end

            -- Poll for more data
            while true do
                curl.curl_multi_perform(multi, running)

                -- Check if new chunks arrived
                if chunk_idx <= chunk_count then
                    local c = chunks[chunk_idx]
                    chunk_idx = chunk_idx + 1
                    return c
                end

                -- Transfer complete
                if (running as any)[0] == 0 then
                    transfer_done = true
                    cleanup()
                    return nil
                end

                -- Wait for activity
                curl.curl_multi_wait(multi, nil, 0, 1000, numfds)
            end
        end
        ;(jit as any).off(body_reader)

        return {
            status_code = status_code,
            headers = resp_headers,
            body = body_reader,
            close = cleanup,
        } as http.Response, nil
    end
    ;(jit as any).off(do_request)
    return { roundtrip = function(_self: http.HttpClient, req: http.Request): async.Operation<http.Response>
        local op = async.new_operation()
        local result, err = do_request(req as StreamingRequest)
        op:resolve(result, err)
        return op
    end } as http.HttpClient
end

return M
