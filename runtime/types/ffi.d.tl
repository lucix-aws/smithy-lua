-- Type declarations for LuaJIT FFI
local record ffi
    record CType end

    record CData
        metamethod __index: function(CData, integer): any
        metamethod __newindex: function(CData, integer, any)
        free: function(CData)
    end

    cdef: function(def: string)
    new: function(ct: any, ...: any): CData
    typeof: function(ct: string, ...: any): CType
    cast: function(ct: any, init: any): CData
    metatype: function(ct: CType, metatable: table): CType
    gc: function(cdata: CData, finalizer: function(CData)): CData
    sizeof: function(ct: any, nelem?: number): number
    alignof: function(ct: any): number
    offsetof: function(ct: any, field: string): number
    istype: function(ct: any, obj: any): boolean
    errno: function(newerr?: number): number
    string: function(ptr: CData, len?: number): string
    copy: function(dst: CData, src: any, len?: number)
    fill: function(dst: CData, len: number, c?: number)
    load: function(name: string, global?: boolean): CData
    os: string
    arch: string
    C: CData
end

return ffi
