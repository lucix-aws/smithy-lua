package software.amazon.smithy.lua.codegen;

import java.util.Map;
import java.util.TreeMap;
import software.amazon.smithy.codegen.core.ImportContainer;
import software.amazon.smithy.codegen.core.Symbol;

/**
 * Tracks Lua require() imports for a generated file.
 *
 * <p>Produces a block like:
 * <pre>
 * local types = require("weather.types")
 * local client = require("smithy.client")
 * </pre>
 */
public final class LuaImportContainer implements ImportContainer {
    private final String namespace;
    private final Map<String, String> imports = new TreeMap<>();

    public LuaImportContainer(String namespace) {
        this.namespace = namespace;
    }

    @Override
    public void importSymbol(Symbol symbol, String alias) {
        if (symbol.getNamespace().isEmpty() || symbol.getDefinitionFile().isEmpty()) {
            return;
        }
        // Derive the require path from the definition file: "weather/types.tl" -> "weather.types"
        String requirePath = symbol.getDefinitionFile()
                .replace(".tl", "")
                .replace(".lua", "")
                .replace("/", ".");
        // The local variable name is the last segment: "weather.types" -> "types"
        String localName = alias != null && !alias.isEmpty() ? alias : lastSegment(requirePath);
        imports.put(localName, requirePath);
    }

    /**
     * Adds a raw require() import.
     */
    public void addImport(String localName, String requirePath) {
        imports.put(localName, requirePath);
    }

    @Override
    public String toString() {
        if (imports.isEmpty()) {
            return "";
        }
        var sb = new StringBuilder();
        for (var entry : imports.entrySet()) {
            sb.append("local ").append(entry.getKey())
              .append(" = require(\"").append(entry.getValue()).append("\")\n");
        }
        return sb.toString();
    }

    private static String lastSegment(String path) {
        int idx = path.lastIndexOf('.');
        return idx >= 0 ? path.substring(idx + 1) : path;
    }
}
