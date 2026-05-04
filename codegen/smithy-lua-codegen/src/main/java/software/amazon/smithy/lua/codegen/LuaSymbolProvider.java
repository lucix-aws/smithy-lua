package software.amazon.smithy.lua.codegen;

import software.amazon.smithy.codegen.core.Symbol;
import software.amazon.smithy.codegen.core.SymbolProvider;
import software.amazon.smithy.model.Model;
import software.amazon.smithy.model.shapes.BigDecimalShape;
import software.amazon.smithy.model.shapes.BigIntegerShape;
import software.amazon.smithy.model.shapes.BlobShape;
import software.amazon.smithy.model.shapes.BooleanShape;
import software.amazon.smithy.model.shapes.ByteShape;
import software.amazon.smithy.model.shapes.DocumentShape;
import software.amazon.smithy.model.shapes.DoubleShape;
import software.amazon.smithy.model.shapes.EnumShape;
import software.amazon.smithy.model.shapes.FloatShape;
import software.amazon.smithy.model.shapes.IntEnumShape;
import software.amazon.smithy.model.shapes.IntegerShape;
import software.amazon.smithy.model.shapes.ListShape;
import software.amazon.smithy.model.shapes.LongShape;
import software.amazon.smithy.model.shapes.MapShape;
import software.amazon.smithy.model.shapes.MemberShape;
import software.amazon.smithy.model.shapes.OperationShape;
import software.amazon.smithy.model.shapes.ResourceShape;
import software.amazon.smithy.model.shapes.ServiceShape;
import software.amazon.smithy.model.shapes.Shape;
import software.amazon.smithy.model.shapes.ShapeVisitor;
import software.amazon.smithy.model.shapes.ShortShape;
import software.amazon.smithy.model.shapes.StringShape;
import software.amazon.smithy.model.shapes.StructureShape;
import software.amazon.smithy.model.shapes.TimestampShape;
import software.amazon.smithy.model.shapes.UnionShape;
import software.amazon.smithy.utils.StringUtils;

/**
 * Maps Smithy shapes to Lua symbols.
 *
 * <p>Generated file layout per service (e.g. example.weather#Weather):
 * <pre>
 * weather/
 *   client.lua   -- service client with constructor + operations
 *   types.lua    -- all structure/union/error/enum schemas
 * </pre>
 */
public final class LuaSymbolProvider implements SymbolProvider, ShapeVisitor<Symbol> {
    private final Model model;
    private final ServiceShape service;
    private final String serviceNamespace;

    public LuaSymbolProvider(Model model, ServiceShape service) {
        this.model = model;
        this.service = service;
        this.serviceNamespace = getServiceNamespace(service);
    }

    static String getServiceNamespace(ServiceShape service) {
        // Use sdkId from aws.api#service trait when available (unique per AWS service).
        // Normalize: remove dashes/spaces, lowercase.
        var serviceTrait = service.findTrait("aws.api#service");
        if (serviceTrait.isPresent()) {
            var sdkId = serviceTrait.get().toNode().expectObjectNode()
                    .getStringMember("sdkId");
            if (sdkId.isPresent()) {
                return sdkId.get().getValue()
                        .replace("-", "")
                        .replace(" ", "")
                        .toLowerCase();
            }
        }
        return StringUtils.uncapitalize(service.getId().getName());
    }

    @Override
    public Symbol toSymbol(Shape shape) {
        return shape.accept(this);
    }

    // --- Aggregate shapes: these get generated into types.lua ---

    @Override
    public Symbol structureShape(StructureShape shape) {
        return typesSymbol(shape);
    }

    @Override
    public Symbol unionShape(UnionShape shape) {
        return typesSymbol(shape);
    }

    @Override
    public Symbol enumShape(EnumShape shape) {
        return typesSymbol(shape);
    }

    @Override
    public Symbol intEnumShape(IntEnumShape shape) {
        return typesSymbol(shape);
    }

    // --- Service/operation/resource: client.lua ---

    @Override
    public Symbol serviceShape(ServiceShape shape) {
        return Symbol.builder()
                .name("Client")
                .namespace(serviceNamespace, ".")
                .definitionFile(serviceNamespace + "/client.lua")
                .build();
    }

    @Override
    public Symbol operationShape(OperationShape shape) {
        return Symbol.builder()
                .name(StringUtils.uncapitalize(shape.getId().getName(service)))
                .namespace(serviceNamespace, ".")
                .definitionFile(serviceNamespace + "/client.lua")
                .build();
    }

    @Override
    public Symbol resourceShape(ResourceShape shape) {
        return typesSymbol(shape);
    }

    // --- Simple shapes: Lua native types, no generated file ---

    @Override
    public Symbol blobShape(BlobShape shape) {
        return simpleSymbol("string");
    }

    @Override
    public Symbol booleanShape(BooleanShape shape) {
        return simpleSymbol("boolean");
    }

    @Override
    public Symbol byteShape(ByteShape shape) {
        return simpleSymbol("number");
    }

    @Override
    public Symbol shortShape(ShortShape shape) {
        return simpleSymbol("number");
    }

    @Override
    public Symbol integerShape(IntegerShape shape) {
        return simpleSymbol("number");
    }

    @Override
    public Symbol longShape(LongShape shape) {
        return simpleSymbol("number");
    }

    @Override
    public Symbol floatShape(FloatShape shape) {
        return simpleSymbol("number");
    }

    @Override
    public Symbol doubleShape(DoubleShape shape) {
        return simpleSymbol("number");
    }

    @Override
    public Symbol bigIntegerShape(BigIntegerShape shape) {
        return simpleSymbol("number");
    }

    @Override
    public Symbol bigDecimalShape(BigDecimalShape shape) {
        return simpleSymbol("number");
    }

    @Override
    public Symbol stringShape(StringShape shape) {
        return simpleSymbol("string");
    }

    @Override
    public Symbol timestampShape(TimestampShape shape) {
        return simpleSymbol("number");
    }

    @Override
    public Symbol documentShape(DocumentShape shape) {
        return simpleSymbol("any");
    }

    @Override
    public Symbol listShape(ListShape shape) {
        return simpleSymbol("table");
    }

    @Override
    public Symbol mapShape(MapShape shape) {
        return simpleSymbol("table");
    }

    @Override
    public Symbol memberShape(MemberShape shape) {
        return toSymbol(model.expectShape(shape.getTarget()));
    }

    // --- Helpers ---

    private Symbol typesSymbol(Shape shape) {
        String name = shape.getId().getName(service);
        return Symbol.builder()
                .name(name)
                .namespace(serviceNamespace, ".")
                .definitionFile(serviceNamespace + "/types.lua")
                .build();
    }

    private Symbol simpleSymbol(String name) {
        return Symbol.builder()
                .name(name)
                .build();
    }
}
