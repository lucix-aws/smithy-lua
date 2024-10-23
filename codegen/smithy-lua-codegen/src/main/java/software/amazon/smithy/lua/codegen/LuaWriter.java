package software.amazon.smithy.lua.codegen;

import software.amazon.smithy.codegen.core.SymbolWriter;
import software.amazon.smithy.utils.SmithyInternalApi;

@SmithyInternalApi
public final class LuaWriter extends SymbolWriter<LuaWriter, LuaImportContainer> {
    public LuaWriter() {
        super(new LuaImportContainer());
    }
}
