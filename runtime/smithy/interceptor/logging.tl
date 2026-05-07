-- smithy-lua runtime: request/response logging interceptor

local http = require("smithy.http")

local record M
    new: function(): Interceptor

    record Interceptor
        read_before_transmit: function(self: Interceptor, ctx: {string:any})
        read_after_transmit: function(self: Interceptor, ctx: {string:any})
    end
end

local Interceptor: {string:any} = {}
Interceptor.__index = Interceptor

function M.new(): M.Interceptor
    return setmetatable({}, Interceptor) as M.Interceptor
end

(Interceptor as {string:function}).read_before_transmit = function(self: any, ctx: {string:any})
    local req = ctx.request as {string:any}
    local headers = req.headers as {string:string}
    io.stderr:write("~~ SDK Request ~~\n")
    io.stderr:write((req.method as string) .. " " .. (req.url as string) .. "\n")
    for k, v in pairs(headers) do
        io.stderr:write(k .. ": " .. v .. "\n")
    end
    if req.body then
        local body, _ = http.read_all(req.body as http.Reader)
        if body then
            io.stderr:write("\n" .. body .. "\n")
            req.body = http.string_reader(body)
        end
    end
    io.stderr:write("\n")
end

(Interceptor as {string:function}).read_after_transmit = function(self: any, ctx: {string:any})
    local resp = ctx.response as {string:any}
    local headers = resp.headers as {string:string}
    io.stderr:write("~~ SDK Response ~~\n")
    io.stderr:write(tostring(resp.status_code) .. "\n")
    for k, v in pairs(headers) do
        io.stderr:write(k .. ": " .. v .. "\n")
    end
    io.stderr:write("\n")
end

return M
