-- Teal declarations for smithy.interceptor

local record interceptor

    -- Context table passed to interceptor hooks.
    -- Fields are populated progressively as the pipeline advances.
    record Context
        input: any
        operation: any
        request: any
        response: any
        output: any
    end

    -- An interceptor is a table with optional hook methods.
    -- "read" hooks observe only; "modify" hooks return a new value.
    record Interceptor
        read_before_execution: function(self: Interceptor, ctx: Context)
        modify_before_serialization: function(self: Interceptor, ctx: Context): any
        read_before_serialization: function(self: Interceptor, ctx: Context)
        read_after_serialization: function(self: Interceptor, ctx: Context)
        modify_before_retry_loop: function(self: Interceptor, ctx: Context): any
        read_before_attempt: function(self: Interceptor, ctx: Context)
        modify_before_signing: function(self: Interceptor, ctx: Context): any
        read_before_signing: function(self: Interceptor, ctx: Context)
        read_after_signing: function(self: Interceptor, ctx: Context)
        modify_before_transmit: function(self: Interceptor, ctx: Context): any
        read_before_transmit: function(self: Interceptor, ctx: Context)
        read_after_transmit: function(self: Interceptor, ctx: Context)
        modify_before_deserialization: function(self: Interceptor, ctx: Context): any
        read_before_deserialization: function(self: Interceptor, ctx: Context)
        read_after_deserialization: function(self: Interceptor, ctx: Context)
        modify_before_attempt_completion: function(self: Interceptor, ctx: Context, err: any): any, any
        read_after_attempt: function(self: Interceptor, ctx: Context, err: any)
        modify_before_completion: function(self: Interceptor, ctx: Context, err: any): any, any
        read_after_execution: function(self: Interceptor, ctx: Context, err: any)
    end

    run_read: function(interceptors: {Interceptor}, hook_name: string, ctx: Context): any
    run_modify: function(interceptors: {Interceptor}, hook_name: string, ctx: Context, field: string): any, any
    run_modify_completion: function(interceptors: {Interceptor}, hook_name: string, ctx: Context, err: any): any, any
    run_read_with_error: function(interceptors: {Interceptor}, hook_name: string, ctx: Context, err: any): any

end

return interceptor
