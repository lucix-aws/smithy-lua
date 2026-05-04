-- HTTP client using libcurl via LuaJIT FFI.
-- Conforms to: function(request) -> response, err

local ffi = require("ffi")
local http = require("smithy.http")

ffi.cdef[[
typedef void CURL;
typedef int CURLcode;

CURL *curl_easy_init(void);
void curl_easy_cleanup(CURL *handle);
CURLcode curl_easy_setopt(CURL *handle, int option, ...);
CURLcode curl_easy_perform(CURL *handle);
CURLcode curl_easy_getinfo(CURL *handle, int info, ...);
const char *curl_easy_strerror(CURLcode code);

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

--- Create an HTTP client backed by libcurl FFI.
function M.new()
    return function(request)
        local handle = curl.curl_easy_init()
        if handle == nil then
            return nil, { type = "http", code = "CurlError", message = "curl_easy_init failed" }
        end

        -- Collect response data via callbacks
        local resp_chunks = {}
        local resp_headers = {}

        local write_cb = ffi.cast("size_t (*)(char *, size_t, size_t, void *)",
            function(ptr, size, nmemb, _)
                local len = size * nmemb
                resp_chunks[#resp_chunks + 1] = ffi.string(ptr, len)
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
                curl.curl_easy_cleanup(handle)
                return nil, { type = "http", code = "ReadError", message = err }
            end
            body = b or ""
        end
        if #body > 0 then
            curl.curl_easy_setopt(handle, CURLOPT_POSTFIELDS, body)
            curl.curl_easy_setopt(handle, CURLOPT_POSTFIELDSIZE, ffi.cast("long", #body))
        end

        -- Perform
        local rc = curl.curl_easy_perform(handle)

        if rc ~= 0 then
            local msg = ffi.string(curl.curl_easy_strerror(rc))
            write_cb:free()
            header_cb:free()
            if slist ~= nil then curl.curl_slist_free_all(slist) end
            curl.curl_easy_cleanup(handle)
            return nil, { type = "http", code = "CurlError", message = msg }
        end

        -- Status code
        local code_buf = ffi.new("long[1]")
        curl.curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, code_buf)
        local status_code = tonumber(code_buf[0])

        -- Cleanup
        write_cb:free()
        header_cb:free()
        if slist ~= nil then curl.curl_slist_free_all(slist) end
        curl.curl_easy_cleanup(handle)

        return {
            status_code = status_code,
            headers = resp_headers,
            body = http.string_reader(table.concat(resp_chunks)),
        }, nil
    end
end

return M
