rootProject.name = "smithy-lua-codegen"

include(":smithy-lua-codegen")
include(":smithy-lua-codegen-test")
include(":protocoltest")
project(":protocoltest").projectDir = file("../protocoltest")
