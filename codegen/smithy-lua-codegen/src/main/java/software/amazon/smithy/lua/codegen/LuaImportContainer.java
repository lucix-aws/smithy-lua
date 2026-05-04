package software.amazon.smithy.lua.codegen;

import software.amazon.smithy.codegen.core.ImportContainer;
import software.amazon.smithy.codegen.core.Symbol;

/**
 * Manages Lua require() imports for a generated file.
 */
public final class LuaImportContainer implements ImportContainer {
    @Override
    public void importSymbol(Symbol symbol, String alias) {
        // TODO: track require() statements for generated Lua files
    }
}
