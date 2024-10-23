package software.amazon.smithy.lua.codegen;

import software.amazon.smithy.codegen.core.Symbol;
import software.amazon.smithy.codegen.core.SymbolProvider;
import software.amazon.smithy.model.shapes.Shape;
import software.amazon.smithy.utils.SmithyInternalApi;

@SmithyInternalApi
public class LuaSymbolProvider implements SymbolProvider {
    @Override
    public Symbol toSymbol(Shape shape) {
        return null;
    }
}
