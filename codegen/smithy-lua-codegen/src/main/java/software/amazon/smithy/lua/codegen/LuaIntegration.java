package software.amazon.smithy.lua.codegen;

import software.amazon.smithy.codegen.core.SmithyIntegration;
import software.amazon.smithy.utils.SmithyInternalApi;

@SmithyInternalApi
public interface LuaIntegration extends SmithyIntegration<LuaSettings, LuaWriter, LuaCodegenContext> {
    default void writeAdditionalSource(LuaCodegenContext ctx) {}
}
