-- Type declarations for LuaJIT FFI
local record ffi
    record CType end
    record CData end

    cdef: function(def: string)
    new: function(ct: CType|string, ...: any): CData
    typeof: function(ct: string, ...: any): CType
    cast: function(ct: CType|string, init: any): CData
    metatype: function(ct: CType, metatable: table): CType
    gc: function(cdata: CData, finalizer: function(CData)): CData
    sizeof: function(ct: CType|CData|string, nelem?: number): number
    alignof: function(ct: CType|CData|string): number
    offsetof: function(ct: CType|CData|string, field: string): number
    istype: function(ct: CType|string, obj: any): boolean
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
