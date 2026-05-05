-- smithy-lua runtime: ShapeId type
-- Represents a Smithy shape identifier (namespace#Name or namespace#Name$member).

local ShapeId = {}
ShapeId.__index = ShapeId

function ShapeId:__tostring()
    if self.member then
        return self.namespace .. "#" .. self.name .. "$" .. self.member
    end
    return self.namespace .. "#" .. self.name
end

function ShapeId:__eq(other)
    return self.namespace == other.namespace
        and self.name == other.name
        and self.member == other.member
end

local function from(namespace, name, member)
    return setmetatable({ namespace = namespace, name = name, member = member }, ShapeId)
end

return { from = from }
