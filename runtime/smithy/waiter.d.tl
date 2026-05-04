local record waiter

    record PathMatcher
        path: string
        expected: string
        comparator: string -- "stringEquals" | "booleanEquals" | "allStringEquals" | "anyStringEquals"
    end

    record Matcher
        success: boolean
        errorType: string
        output: PathMatcher
        inputOutput: PathMatcher
    end

    record Acceptor
        state: string -- "success" | "failure" | "retry"
        matcher: Matcher
    end

    record WaiterConfig
        acceptors: {Acceptor}
        min_delay: number
        max_delay: number
    end

    record WaitOptions
        max_wait_time: number
    end

    compute_delay: function(attempt: number, min_delay: number, max_delay: number): number
    wait: function(client: table, operation_fn: string, input: table, waiter_config: WaiterConfig, options: WaitOptions): table, table
end

return waiter
