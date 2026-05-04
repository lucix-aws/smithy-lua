package software.amazon.smithy.lua.codegen;

/**
 * A config resolver to emit in the generated client constructor.
 *
 * <p>Each resolver is a Lua function call that checks if a config field is set
 * and fills in a default if not. The codegen emits these as calls in the
 * generated {@code new(cfg)} function.
 *
 * @param requirePath the Lua module to require (e.g. "defaults")
 * @param requireAlias the local variable name for the require (e.g. "defaults")
 * @param functionCall the Lua expression to emit (e.g. "defaults.resolve_http_client(cfg)")
 */
public record ConfigResolver(
        String requirePath,
        String requireAlias,
        String functionCall
) {}
