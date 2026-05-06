package software.amazon.smithy.lua.codegen;

import java.util.Collections;
import java.util.List;
import software.amazon.smithy.codegen.core.SmithyIntegration;
import software.amazon.smithy.model.shapes.ShapeId;

public interface LuaIntegration
        extends SmithyIntegration<LuaSettings, LuaWriter, LuaContext> {

    /**
     * Returns whether this integration applies to the given service.
     *
     * <p>Integrations that are service-specific (e.g. S3 customizations)
     * override this to return true only for their target service. The
     * codegen pipeline skips integrations that return false for the
     * service being generated.
     *
     * @param service the shape ID of the service being generated
     * @return true if this integration should run for the given service
     */
    default boolean forService(ShapeId service) {
        return true;
    }

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

    /**
     * Returns config resolvers to emit in the generated client constructor.
     *
     * <p>Each resolver is a Lua function call that checks if a config field
     * is set and fills in a default if not. Resolvers from all integrations
     * are collected and emitted in order in the generated {@code new(cfg)}.
     *
     * <p>The base smithy-lua codegen registers resolvers for generic Smithy
     * client concerns (endpoint, protocol, signer, http_client, retry).
     * AWS SDK codegen adds SDK-specific resolvers (identity_resolver).
     *
     * @param context the codegen context
     * @return list of config resolvers
     */
    default List<ConfigResolver> getConfigResolvers(LuaContext context) {
        return Collections.emptyList();
    }

    /**
     * Returns config finalizers to emit after client construction (post-setmetatable).
     *
     * <p>These are emitted after {@code local self = setmetatable(...)} in the
     * generated constructor, allowing access to the constructed client instance.
     * The function call expression can reference both {@code cfg} and {@code self}.
     *
     * @param context the codegen context
     * @return list of config finalizers
     */
    default List<ConfigResolver> getConfigFinalizers(LuaContext context) {
        return Collections.emptyList();
    }
}
