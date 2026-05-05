-- HTTP client using libcurl via LuaJIT FFI (curl_multi for streaming).
-- Conforms to: function(request) -> response, err

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

-- CURLINFO constants
local CURLINFO_RESPONSE_CODE = 0x200002

local M = {}

--- Check if this backend is available.
function M.available()
    local ok = pcall(ffi.load, "curl")
    return ok
end

--- Create an HTTP client backed by libcurl FFI with streaming response.
function M.new()
    return function(request)
        local handle = curl.curl_easy_init()
        if handle == nil then
            return nil, { type = "http", code = "CurlError", message = "curl_easy_init failed" }
        end

        local multi = curl.curl_multi_init()
        if multi == nil then
            curl.curl_easy_cleanup(handle)
            return nil, { type = "http", code = "CurlError", message = "curl_multi_init failed" }
        end

        -- Chunks buffer: write callback pushes, body reader pops
        local chunks = {}
        local headers_done = false
        local transfer_done = false
        local resp_headers = {}

        local write_cb = ffi.cast("size_t (*)(char *, size_t, size_t, void *)",
            function(ptr, size, nmemb, _)
                local len = size * nmemb
                chunks[#chunks + 1] = ffi.string(ptr, len)
                return len
            end)

        local header_cb = ffi.cast("size_t (*)(char *, size_t, size_t, void *)",
            function(ptr, size, nmemb, _)
                local len = size * nmemb
                local line = ffi.string(ptr, len)
                local k, v = line:match("^([^:]+):%s*(.-)%s*$")
                if k then resp_headers[k:lower()] = v end
                return len
            end)

        -- Set options
        curl.curl_easy_setopt(handle, CURLOPT_URL, request.url)
        curl.curl_easy_setopt(handle, CURLOPT_CUSTOMREQUEST, request.method)
        curl.curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, write_cb)
        curl.curl_easy_setopt(handle, CURLOPT_HEADERFUNCTION, header_cb)

        -- Headers
        local slist = nil
        for k, v in pairs(request.headers or {}) do
            slist = curl.curl_slist_append(slist, k .. ": " .. v)
        end
        if slist ~= nil then
            curl.curl_easy_setopt(handle, CURLOPT_HTTPHEADER, slist)
        end

        -- Body
        local body = ""
        if request.body then
            local b, err = http.read_all(request.body)
            if err then
                write_cb:free()
                header_cb:free()
                if slist ~= nil then curl.curl_slist_free_all(slist) end
                curl.curl_multi_cleanup(multi)
                curl.curl_easy_cleanup(handle)
                return nil, { type = "http", code = "ReadError", message = err }
            end
            body = b or ""
        end
        if #body > 0 then
            curl.curl_easy_setopt(handle, CURLOPT_POSTFIELDS, body)
            curl.curl_easy_setopt(handle, CURLOPT_POSTFIELDSIZE, ffi.cast("long", #body))
        end

        -- Add to multi handle
        curl.curl_multi_add_handle(multi, handle)

        -- Poll until we have response headers (status code available)
        local running = ffi.new("int[1]")
        local numfds = ffi.new("int[1]")
        while true do
            curl.curl_multi_perform(multi, running)
            -- Check if we have a status code yet
            local code_buf = ffi.new("long[1]")
            curl.curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, code_buf)
            if code_buf[0] ~= 0 then
                break
            end
            -- Transfer finished before we got headers (error case)
            if running[0] == 0 then
                break
            end
            curl.curl_multi_wait(multi, nil, 0, 1000, numfds)
        end

        -- Get status code
        local code_buf = ffi.new("long[1]")
        curl.curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, code_buf)
        local status_code = tonumber(code_buf[0])

        if status_code == 0 then
            write_cb:free()
            header_cb:free()
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
                while running[0] > 0 do
                    curl.curl_multi_perform(multi, running)
                    if running[0] > 0 then
                        curl.curl_multi_wait(multi, nil, 0, 100, numfds)
                    end
                end
            end
            curl.curl_multi_remove_handle(multi, handle)
            curl.curl_multi_cleanup(multi)
            write_cb:free()
            header_cb:free()
            if slist ~= nil then curl.curl_slist_free_all(slist) end
            curl.curl_easy_cleanup(handle)
        end

        -- Streaming body reader: polls curl_multi for more data
        local chunk_idx = 1
        local body_reader = function()
            -- Return any buffered chunks first
            if chunk_idx <= #chunks then
                local c = chunks[chunk_idx]
                chunks[chunk_idx] = nil -- allow GC
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
                if chunk_idx <= #chunks then
                    local c = chunks[chunk_idx]
                    chunks[chunk_idx] = nil
                    chunk_idx = chunk_idx + 1
                    return c
                end

                -- Transfer complete
                if running[0] == 0 then
                    transfer_done = true
                    cleanup()
                    return nil
                end

                -- Wait for activity
                curl.curl_multi_wait(multi, nil, 0, 1000, numfds)
            end
        end

        return {
            status_code = status_code,
            headers = resp_headers,
            body = body_reader,
            close = cleanup,
        }, nil
    end
end

return M
