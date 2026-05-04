$version: "2.0"

namespace com.example.test

use smithy.waiters#waitable

@aws.api#service(sdkId: "TestWaiters")
@aws.protocols#awsJson1_0
service TestWaitersService {
    version: "2024-01-01"
    operations: [
        DescribeWidget
        HeadWidget
    ]
}

@waitable(
    WidgetExists: {
        documentation: "Wait until a widget exists and is active"
        acceptors: [
            {
                state: "success"
                matcher: {
                    output: { path: "Widget.Status", expected: "ACTIVE", comparator: "stringEquals" }
                }
            }
            {
                state: "retry"
                matcher: { errorType: "WidgetNotFoundException" }
            }
            {
                state: "failure"
                matcher: {
                    output: { path: "Widget.Status", expected: "FAILED", comparator: "stringEquals" }
                }
            }
        ]
        minDelay: 5
        maxDelay: 60
    }
    WidgetNotExists: {
        documentation: "Wait until a widget no longer exists"
        acceptors: [
            {
                state: "success"
                matcher: { errorType: "WidgetNotFoundException" }
            }
        ]
        minDelay: 5
        maxDelay: 60
    }
)
operation DescribeWidget {
    input := {
        @required
        WidgetId: String
    }

    output := {
        Widget: WidgetDescription
    }

    errors: [
        WidgetNotFoundException
    ]
}

@waitable(
    WidgetReady: {
        documentation: "Wait until widget is ready"
        acceptors: [
            {
                state: "success"
                matcher: { success: true }
            }
            {
                state: "retry"
                matcher: { errorType: "WidgetNotFoundException" }
            }
        ]
        minDelay: 3
    }
)
operation HeadWidget {
    input := {
        @required
        WidgetId: String
    }

    output := {}

    errors: [
        WidgetNotFoundException
    ]
}

structure WidgetDescription {
    WidgetId: String
    Status: String
}

@error("client")
structure WidgetNotFoundException {
    @required
    message: String
}
