import java.net.URLClassLoader
import software.amazon.smithy.model.Model
import software.amazon.smithy.model.node.Node
import software.amazon.smithy.model.shapes.ServiceShape

val smithyVersion: String by project

buildscript {
    val smithyVersion: String by project
    repositories {
        mavenLocal()
        mavenCentral()
    }
    dependencies {
        "classpath"("software.amazon.smithy:smithy-model:$smithyVersion")
        "classpath"("software.amazon.smithy:smithy-protocol-tests:$smithyVersion")
        "classpath"("software.amazon.smithy:smithy-aws-protocol-tests:$smithyVersion")
    }
}

plugins {
    id("software.amazon.smithy.gradle.smithy-base") version "1.2.0"
}

dependencies {
    smithyBuild(project(":smithy-lua-codegen"))
    smithyBuild("software.amazon.smithy:smithy-model:$smithyVersion")
    smithyBuild("software.amazon.smithy:smithy-aws-traits:$smithyVersion")
    smithyBuild("software.amazon.smithy:smithy-rules-engine:$smithyVersion")
    smithyBuild("software.amazon.smithy:smithy-aws-endpoints:$smithyVersion")
    smithyBuild("software.amazon.smithy:smithy-protocol-tests:$smithyVersion")
    smithyBuild("software.amazon.smithy:smithy-aws-protocol-tests:$smithyVersion")
    smithyBuild("software.amazon.smithy:smithy-protocol-test-traits:$smithyVersion")
}

// Services to exclude (validation tests, etc.)
val excludedServices = setOf(
    "aws.protocoltests.restjson.validation#RestJsonValidation",
    "com.amazonaws.machinelearning#AmazonML_20141212",
    "com.amazonaws.s3#AmazonS3",
    "com.amazonaws.apigateway#BackplaneControlService",
    "com.amazonaws.glacier#Glacier",
)

tasks.register("generate-smithy-build") {
    doLast {
        val model = Model.assembler()
            .discoverModels()
            .assemble()
            .result
            .get()

        val projectionsBuilder = Node.objectNodeBuilder()

        model.shapes(ServiceShape::class.javaObjectType).sorted().forEach { service ->
            val shapeId = service.id.toString()
            if (shapeId in excludedServices) return@forEach

            val svcName = service.id.name
            val projName = svcName.replace(Regex("([a-z0-9])([A-Z])"), "$1-$2").lowercase()

            projectionsBuilder.withMember(projName, Node.objectNodeBuilder()
                .withMember("transforms", Node.fromNodes(
                    Node.objectNodeBuilder()
                        .withMember("name", "includeServices")
                        .withMember("args", Node.objectNode()
                            .withMember("services", Node.fromStrings(shapeId)))
                        .build(),
                    Node.objectNodeBuilder()
                        .withMember("name", "removeUnusedShapes")
                        .build(),
                ))
                .withMember("plugins", Node.objectNode()
                    .withMember("lua-client-codegen", Node.objectNodeBuilder()
                        .withMember("service", shapeId)
                        .build()))
                .build())
        }

        file("smithy-build.json").writeText(Node.prettyPrintJson(Node.objectNodeBuilder()
            .withMember("version", "1.0")
            .withMember("projections", projectionsBuilder.build())
            .build()))

        println("Generated smithy-build.json with projections for protocol test services")
    }
}

tasks.named("smithyBuild") {
    dependsOn("generate-smithy-build")
}
