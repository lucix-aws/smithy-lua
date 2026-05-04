package software.amazon.smithy.lua.codegen;

import software.amazon.smithy.codegen.core.SymbolWriter;

public final class LuaWriter extends SymbolWriter<LuaWriter, LuaImportContainer> {

    public LuaWriter(String namespace) {
        super(new LuaImportContainer());
        trimBlankLines();
        trimTrailingSpaces();
    }
}
