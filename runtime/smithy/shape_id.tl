-- smithy-lua runtime: ShapeId type

local record M
    record ShapeId
        namespace: string
        name: string
        member: string
        metamethod __tostring: function(self: ShapeId): string
        metamethod __eq: function(self: ShapeId, other: ShapeId): boolean
    end
    from: function(namespace: string, name: string, member?: string): ShapeId
end

local ShapeId_mt: metatable<M.ShapeId> = {
    __index = {} as M.ShapeId,
    __tostring = function(self: M.ShapeId): string
        if self.member then
            return self.namespace .. "#" .. self.name .. "$" .. self.member
        end
        return self.namespace .. "#" .. self.name
    end,
    __eq = function(self: M.ShapeId, other: M.ShapeId): boolean
        return self.namespace == other.namespace
            and self.name == other.name
            and self.member == other.member
    end,
}

function M.from(namespace: string, name: string, member?: string): M.ShapeId
    return setmetatable({ namespace = namespace, name = name, member = member } as M.ShapeId, ShapeId_mt)
end

return M
