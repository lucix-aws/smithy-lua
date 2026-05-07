

local M = { ShapeId = {} }










local ShapeId_mt = {
   __index = {},
   __tostring = function(self)
      if self.member then
         return self.namespace .. "#" .. self.name .. "$" .. self.member
      end
      return self.namespace .. "#" .. self.name
   end,
   __eq = function(self, other)
      return self.namespace == other.namespace and
      self.name == other.name and
      self.member == other.member
   end,
}

function M.from(namespace, name, member)
   return setmetatable({ namespace = namespace, name = name, member = member }, ShapeId_mt)
end

return M
