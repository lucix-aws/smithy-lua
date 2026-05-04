package software.amazon.smithy.lua.codegen;

import software.amazon.smithy.codegen.core.SymbolWriter;

/**
 * Writes Lua source code with import tracking and Lua-specific helpers.
 */
public final class LuaWriter extends SymbolWriter<LuaWriter, LuaImportContainer> {

    public LuaWriter(String namespace) {
        super(new LuaImportContainer(namespace));
        trimBlankLines();
        trimTrailingSpaces();
        setRelativizeSymbols(namespace);
    }

    @Override
    public String toString() {
        var imports = getImportContainer().toString();
        var body = super.toString();
        if (imports.isEmpty()) {
            return body;
        }
        return imports + "\n" + body;
    }

    /**
     * Writes a Lua table literal block: {@code \{ ... \}}.
     */
    public LuaWriter openTable() {
        writeInline("{");
        indent();
        return this;
    }

    public LuaWriter closeTable() {
        dedent();
        write("}");
        return this;
    }

    /**
     * Writes a block with braces: opens, runs body, closes.
     * Useful for table literals and function bodies.
     */
    public LuaWriter block(String header, Runnable body) {
        write(header);
        indent();
        body.run();
        dedent();
        write("end");
        return this;
    }

    /**
     * Adds a raw require() import to this file.
     */
    public LuaWriter addRequire(String localName, String requirePath) {
        getImportContainer().addImport(localName, requirePath);
        return this;
    }
}
