local path = require 'pl.path'

local ret = {}

local getTrace = function(filename, info)
  local index = info.traceback:find('\n%s*%[C]')
  info.traceback = info.traceback:sub(1, index)
  return info
end

ret.match = function(busted, filename)
  return path.extension(filename) == '.tl'
end

ret.load = function(busted, filename)
  local tl = require("tl")
  local result, err = tl.process(filename)
  if not result then
    busted.publish({ 'error', 'file' }, { descriptor = 'file', name = filename }, nil, err, {})
    return nil, getTrace
  end
  if result.syntax_errors and #result.syntax_errors > 0 then
    local msg = filename .. ": " .. result.syntax_errors[1].msg
    busted.publish({ 'error', 'file' }, { descriptor = 'file', name = filename }, nil, msg, {})
    return nil, getTrace
  end
  local code = tl.pretty_print_ast(result.ast)
  local file, load_err = load(code, "@" .. filename)
  if not file then
    busted.publish({ 'error', 'file' }, { descriptor = 'file', name = filename }, nil, load_err, {})
  end
  return file, getTrace
end

return ret
