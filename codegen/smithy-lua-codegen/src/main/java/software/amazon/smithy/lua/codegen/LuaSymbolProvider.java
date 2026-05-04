package software.amazon.smithy.lua.codegen;

import software.amazon.smithy.codegen.core.Symbol;
import software.amazon.smithy.codegen.core.SymbolProvider;
import software.amazon.smithy.model.Model;
import software.amazon.smithy.model.shapes.Shape;
import software.amazon.smithy.model.shapes.ServiceShape;
import software.amazon.smithy.utils.StringUtils;

public final class LuaSymbolProvider implements SymbolProvider {
    private final Model model;
    private final ServiceShape service;

    public LuaSymbolProvider(Model model, ServiceShape service) {
        this.model = model;
        this.service = service;
    }

    @Override
    public Symbol toSymbol(Shape shape) {
        var name = StringUtils.capitalize(shape.getId().getName());
        return Symbol.builder()
                .name(name)
                .namespace(service.getId().getNamespace(), "/")
                .definitionFile(name + ".lua")
                .build();
    }
}
