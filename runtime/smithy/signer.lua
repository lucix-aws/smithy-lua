

local sha256 = require("smithy.crypto.sha256")
local hmac = require("smithy.crypto.hmac")
local http = require("smithy.http")

local M = {}




local IGNORED_HEADERS = {
   authorization = true,
   ["user-agent"] = true,
}

function M.uri_encode(s, encode_slash)
   if encode_slash == nil then encode_slash = true end
   local out = {}
   for i = 1, #s do
      local c = string.sub(s, i, i)
      local b = string.byte(c)
      if (b >= 0x41 and b <= 0x5a) or
         (b >= 0x61 and b <= 0x7a) or
         (b >= 0x30 and b <= 0x39) or
         c == "-" or c == "_" or c == "." or c == "~" then
         out[#out + 1] = c
      elseif c == "/" and not encode_slash then
         out[#out + 1] = "/"
      else
         out[#out + 1] = string.format("%%%02X", b)
      end
   end
   return table.concat(out)
end

local function parse_url(url)
   local rest = url:match("^https?://(.+)$") or url
   local host, path_and_query = rest:match("^([^/]+)(/.*)$")
   if not host then
      host = rest
      path_and_query = "/"
   end
   local path, query = path_and_query:match("^([^?]+)%?(.+)$")
   if not path then
      path = path_and_query
      query = ""
   end
   return host, path, query
end

local function canonical_query_string(query)
   if query == "" then return "" end
   local params = {}
   for pair in query:gmatch("[^&]+") do
      local k, v = pair:match("^([^=]+)=(.*)$")
      if k then
         params[#params + 1] = { M.uri_encode(k, true), M.uri_encode(v, true) }
      else
         params[#params + 1] = { M.uri_encode(pair, true), "" }
      end
   end
   table.sort(params, function(a, b)
      if a[1] == b[1] then return a[2] < b[2] end
      return a[1] < b[1]
   end)
   local parts = {}
   for i = 1, #params do
      parts[i] = params[i][1] .. "=" .. params[i][2]
   end
   return table.concat(parts, "&")
end

local function canonical_path(path, disable_double_encoding)
   if path == "" or path == "/" then return "/" end
   if disable_double_encoding then
      return path
   end
   local segments = {}
   for seg in path:gmatch("[^/]+") do
      segments[#segments + 1] = M.uri_encode(seg, true)
   end
   local result = "/" .. table.concat(segments, "/")
   if path:sub(-1) == "/" then result = result .. "/" end
   return result
end

function M.sign(request, identity, props)
   local req = request
   local id = identity
   local headers = req.headers
   if not headers then
      headers = {}
      req.headers = headers
   end

   local host, path, query = parse_url(req.url)

   local body = ""
   local payload_hash = headers["X-Amz-Content-Sha256"]
   if not payload_hash then
      if req.body then
         local b, err = http.read_all(req.body)
         if err then return nil, { type = "sdk", code = "SigningError", message = err } end
         body = b or ""
      end
      payload_hash = sha256.hex_digest(body)
   end

   headers["Host"] = host
   headers["X-Amz-Content-Sha256"] = payload_hash

   local amz_date = headers["X-Amz-Date"]
   if not amz_date then
      amz_date = os.date("!%Y%m%dT%H%M%SZ")
      headers["X-Amz-Date"] = amz_date
   end
   local date_stamp = amz_date:sub(1, 8)

   if id.session_token then
      headers["X-Amz-Security-Token"] = id.session_token
   end

   local signed = {}
   for k, _ in pairs(headers) do
      local lk = k:lower()
      if not IGNORED_HEADERS[lk] then
         signed[#signed + 1] = lk
      end
   end
   table.sort(signed)
   local signed_headers = table.concat(signed, ";")

   local lower_map = {}
   for k, v in pairs(headers) do
      lower_map[k:lower()] = v
   end
   local canonical_hdrs = {}
   for i = 1, #signed do
      canonical_hdrs[i] = signed[i] .. ":" .. lower_map[signed[i]]:gsub("^%s+", ""):gsub("%s+$", "")
   end
   local canonical_headers_str = table.concat(canonical_hdrs, "\n") .. "\n"

   local signing_region = props.signing_region
   local signing_name = props.signing_name
   local disable_double = props.disable_double_encoding

   local canonical_request = table.concat({
      req.method,
      canonical_path(path, disable_double),
      canonical_query_string(query),
      canonical_headers_str,
      signed_headers,
      payload_hash,
   }, "\n")

   local scope = date_stamp .. "/" .. signing_region .. "/" .. signing_name .. "/aws4_request"
   local string_to_sign = table.concat({
      "AWS4-HMAC-SHA256",
      amz_date,
      scope,
      sha256.hex_digest(canonical_request),
   }, "\n")

   local k_date = hmac.digest("AWS4" .. (id.secret_key), date_stamp)
   local k_region = hmac.digest(k_date, signing_region)
   local k_service = hmac.digest(k_region, signing_name)
   local k_signing = hmac.digest(k_service, "aws4_request")

   local signature = hmac.hex_digest(k_signing, string_to_sign)

   headers["Authorization"] = string.format(
   "AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s",
   id.access_key, scope, signed_headers, signature)

   if #body > 0 then
      req.body = http.string_reader(body)
   elseif body == "" and not req.streaming then
      req.body = nil
   end

   return request, nil
end

return M
