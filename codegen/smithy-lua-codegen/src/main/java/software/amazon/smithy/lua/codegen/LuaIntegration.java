package software.amazon.smithy.lua.codegen;

import software.amazon.smithy.codegen.core.SmithyIntegration;

public interface LuaIntegration
        extends SmithyIntegration<LuaSettings, LuaWriter, LuaContext> {

    /**
     * Hook for integrations to write additional generated source files.
     *
     * <p>Called after all standard codegen is complete. The full LuaContext
     * is available, including the writer delegator, model, and service.
     *
     * @param context the codegen context
     */
    default void writeAdditionalFiles(LuaContext context) {
        // no-op by default
    }
}
