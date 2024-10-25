package software.amazon.smithy.lua.codegen;

import software.amazon.smithy.codegen.core.SymbolWriter;
import software.amazon.smithy.utils.SmithyInternalApi;

@SmithyInternalApi
public final class LuaWriter extends SymbolWriter<LuaWriter, LuaImportContainer> {
    public LuaWriter() {
        super(new LuaImportContainer());
    }

    @Override
    public String toString() {
        var imports = getImportContainer().getRequires();
        var preamble = new StringBuilder();
        for (var entry: imports.entrySet()) {
            preamble.append("local ").append(entry.getKey())
                    // TODO assumes you're dropping the runtime directory where the client is for now,
                    //      hence the ./
                    .append(" = require('./").append(entry.getValue()).append("')\n");
        }
        return preamble + "\n" + super.toString();
    }
}
