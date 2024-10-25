package software.amazon.smithy.lua.codegen;

import software.amazon.smithy.codegen.core.ImportContainer;
import software.amazon.smithy.codegen.core.Symbol;
import software.amazon.smithy.utils.SmithyInternalApi;

import java.util.HashSet;
import java.util.Map;
import java.util.Set;

import static java.util.stream.Collectors.toMap;

@SmithyInternalApi
public final class LuaImportContainer implements ImportContainer {
    private final Set<Symbol> symbols = new HashSet<>();

    @Override
    public void importSymbol(Symbol symbol, String s) {
        symbols.add(symbol);
    }

    public Map<String, String> getRequires() {
        return symbols.stream()
                .collect(toMap(Symbol::getNamespace, Symbol::getDefinitionFile, (i, j) -> i));
    }
}
