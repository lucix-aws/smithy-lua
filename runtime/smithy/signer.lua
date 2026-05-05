

local sha256 = require("smithy.crypto.sha256")
local hmac = require("smithy.crypto.hmac")
local http_mod = require("smithy.http")
local auth_mod = require("smithy.auth")

local signer_mod = {}


local IGNORED_HEADERS = {
   authorization = true,
   ["user-agent"] = true,
}

function signer_mod.uri_encode(s, encode_slash)
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
         params[#params + 1] = { signer_mod.uri_encode(k, true), signer_mod.uri_encode(v, true) }
      else
         params[#params + 1] = { signer_mod.uri_encode(pair, true), "" }
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

local function canonical_path(path)
   if path == "" or path == "/" then return "/" end
   local segments = {}
   for seg in path:gmatch("[^/]+") do
      segments[#segments + 1] = signer_mod.uri_encode(seg, true)
   end
   local result = "/" .. table.concat(segments, "/")
   if path:sub(-1) == "/" then result = result .. "/" end
   return result
end

function signer_mod.sign(request, identity, props)
   local creds = identity
   local host, path, query = parse_url(request.url)

   local body = ""
   if request.body then
      local b, err = http_mod.read_all(request.body)
      if err then return nil, { type = "sdk", code = "SigningError", message = err } end
      body = b or ""
   end
   local payload_hash = sha256.hex_digest(body)

   request.headers = request.headers or {}
   request.headers["Host"] = host
   request.headers["X-Amz-Content-Sha256"] = payload_hash

   local amz_date = request.headers["X-Amz-Date"]
   if not amz_date then
      amz_date = os.date("!%Y%m%dT%H%M%SZ")
      request.headers["X-Amz-Date"] = amz_date
   end
   local date_stamp = amz_date:sub(1, 8)

   if creds.session_token then
      request.headers["X-Amz-Security-Token"] = creds.session_token
   end

   local signed = {}
   for k, _ in pairs(request.headers) do
      local lk = k:lower()
      if not IGNORED_HEADERS[lk] then
         signed[#signed + 1] = lk
      end
   end
   table.sort(signed)
   local signed_headers = table.concat(signed, ";")

   local lower_map = {}
   for k, v in pairs(request.headers) do
      lower_map[k:lower()] = v
   end
   local canonical_hdrs = {}
   for i = 1, #signed do
      canonical_hdrs[i] = signed[i] .. ":" .. lower_map[signed[i]]:gsub("^%s+", ""):gsub("%s+$", "")
   end
   local canonical_headers_str = table.concat(canonical_hdrs, "\n") .. "\n"

   local canonical_request = table.concat({
      request.method,
      canonical_path(path),
      canonical_query_string(query),
      canonical_headers_str,
      signed_headers,
      payload_hash,
   }, "\n")

   local scope = date_stamp .. "/" .. props.signing_region .. "/" .. props.signing_name .. "/aws4_request"
   local string_to_sign = table.concat({
      "AWS4-HMAC-SHA256",
      amz_date,
      scope,
      sha256.hex_digest(canonical_request),
   }, "\n")

   local k_date = hmac.digest("AWS4" .. creds.secret_key, date_stamp)
   local k_region = hmac.digest(k_date, props.signing_region)
   local k_service = hmac.digest(k_region, props.signing_name)
   local k_signing = hmac.digest(k_service, "aws4_request")

   local signature = hmac.hex_digest(k_signing, string_to_sign)

   request.headers["Authorization"] = string.format(
   "AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s",
   creds.access_key, scope, signed_headers, signature)

   request.body = http_mod.string_reader(body)

   return request, nil
end

return signer_mod
