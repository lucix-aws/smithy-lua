val smithyVersion: String by project

plugins {
    id("software.amazon.smithy.gradle.smithy-base") version "1.2.0"
}

dependencies {
    smithyBuild(project(":smithy-lua-codegen"))
    smithyBuild("software.amazon.smithy:smithy-model:$smithyVersion")
    smithyBuild("software.amazon.smithy:smithy-aws-traits:$smithyVersion")
    smithyBuild("software.amazon.smithy:smithy-rules-engine:$smithyVersion")
    smithyBuild("software.amazon.smithy:smithy-aws-endpoints:$smithyVersion")
    smithyBuild("software.amazon.smithy:smithy-waiters:$smithyVersion")
}
