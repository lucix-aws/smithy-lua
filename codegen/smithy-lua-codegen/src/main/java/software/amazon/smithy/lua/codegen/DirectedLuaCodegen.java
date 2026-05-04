package software.amazon.smithy.lua.codegen;

import java.util.Locale;
import java.util.TreeMap;
import software.amazon.smithy.codegen.core.SymbolProvider;
import software.amazon.smithy.codegen.core.WriterDelegator;
import software.amazon.smithy.codegen.core.directed.CreateContextDirective;
import software.amazon.smithy.codegen.core.directed.CreateSymbolProviderDirective;
import software.amazon.smithy.codegen.core.directed.CustomizeDirective;
import software.amazon.smithy.codegen.core.directed.DirectedCodegen;
import software.amazon.smithy.codegen.core.directed.GenerateEnumDirective;
import software.amazon.smithy.codegen.core.directed.GenerateErrorDirective;
import software.amazon.smithy.codegen.core.directed.GenerateIntEnumDirective;
import software.amazon.smithy.codegen.core.directed.GenerateServiceDirective;
import software.amazon.smithy.codegen.core.directed.GenerateStructureDirective;
import software.amazon.smithy.codegen.core.directed.GenerateUnionDirective;
import software.amazon.smithy.model.knowledge.OperationIndex;
import software.amazon.smithy.model.knowledge.TopDownIndex;
import software.amazon.smithy.model.shapes.MemberShape;
import software.amazon.smithy.model.shapes.OperationShape;
import software.amazon.smithy.model.shapes.ServiceShape;
import software.amazon.smithy.model.shapes.Shape;
import software.amazon.smithy.model.shapes.ShapeType;
import software.amazon.smithy.model.shapes.StructureShape;
import software.amazon.smithy.model.traits.ErrorTrait;
import software.amazon.smithy.model.traits.HttpHeaderTrait;
import software.amazon.smithy.model.traits.HttpLabelTrait;
import software.amazon.smithy.model.traits.HttpPayloadTrait;
import software.amazon.smithy.model.traits.HttpPrefixHeadersTrait;
import software.amazon.smithy.model.traits.HttpQueryTrait;
import software.amazon.smithy.model.traits.HttpQueryParamsTrait;
import software.amazon.smithy.model.traits.HttpResponseCodeTrait;
import software.amazon.smithy.model.traits.HttpTrait;
import software.amazon.smithy.model.traits.JsonNameTrait;
import software.amazon.smithy.model.traits.RequiredTrait;
import software.amazon.smithy.model.traits.TimestampFormatTrait;
import software.amazon.smithy.model.traits.XmlNameTrait;

public final class DirectedLuaCodegen
        implements DirectedCodegen<LuaContext, LuaSettings, LuaIntegration> {

    @Override
    public SymbolProvider createSymbolProvider(CreateSymbolProviderDirective<LuaSettings> directive) {
        return new LuaSymbolProvider(directive.model(), directive.service());
    }

    @Override
    public LuaContext createContext(CreateContextDirective<LuaSettings, LuaIntegration> directive) {
        return new LuaContext(
                directive.model(),
                directive.settings(),
                directive.symbolProvider(),
                directive.fileManifest(),
                new WriterDelegator<>(directive.fileManifest(),
                        directive.symbolProvider(),
                        (filename, namespace) -> new LuaWriter(namespace)),
                directive.integrations(),
                directive.service()
        );
    }

    @Override
    public void customizeBeforeShapeGeneration(CustomizeDirective<LuaContext, LuaSettings> directive) {
        // Write module header to types.lua before any shapes are generated
        var serviceNs = LuaSymbolProvider.getServiceNamespace(directive.context().service());
        var typesFile = serviceNs + "/types.lua";
        directive.context().writerDelegator().useFileWriter(typesFile, serviceNs, writer -> {
            writer.write("local M = {}");
            writer.write("");
        });
    }

    @Override
    public void customizeBeforeIntegrations(CustomizeDirective<LuaContext, LuaSettings> directive) {
        // Write module footer to types.lua after all shapes are generated
        var serviceNs = LuaSymbolProvider.getServiceNamespace(directive.context().service());
        var typesFile = serviceNs + "/types.lua";
        directive.context().writerDelegator().useFileWriter(typesFile, serviceNs, writer -> {
            writer.write("");
            writer.write("return M");
        });

        // Generate .d.tl Teal declaration files
        TealGenerator.generate(directive.context());
    }

    @Override
    public void customizeAfterIntegrations(CustomizeDirective<LuaContext, LuaSettings> directive) {
        for (var integration : directive.context().integrations()) {
            integration.writeAdditionalFiles(directive.context());
        }
    }

    @Override
    public void generateService(GenerateServiceDirective<LuaContext, LuaSettings> directive) {
        var context = directive.context();
        var service = directive.shape();
        var model = directive.model();
        var symbolProvider = directive.symbolProvider();
        var serviceNs = LuaSymbolProvider.getServiceNamespace(service);

        context.writerDelegator().useShapeWriter(service, writer -> {
            var topDown = TopDownIndex.of(model);
            var operations = topDown.getContainedOperations(service);
            var operationIndex = OperationIndex.of(model);

            // Require base client
            writer.addRequire("base_client", "client");

            // Module table
            writer.write("local M = {}");
            writer.write("");
            writer.write("local Client = {}");
            writer.write("Client.__index = Client");
            writer.write("");
            // Inherit invokeOperation from base client
            writer.write("Client.invokeOperation = base_client.invokeOperation");
            writer.write("");

            // Constructor
            writer.block("function M.new(config)", () -> {
                writer.write("config.service_id = $S", service.getId().getName());
                writer.write("config.signing_name = $S",
                        service.getId().getName().toLowerCase(Locale.US));
                writer.write("local self = setmetatable(base_client.new(config), Client)");
                writer.write("return self");
            });
            writer.write("");

            // Operation methods
            for (var operation : operations) {
                generateOperationMethod(writer, model, symbolProvider, service, operation, operationIndex);
                writer.write("");
            }

            writer.write("return M");
        });
    }

    private void generateOperationMethod(
            LuaWriter writer,
            software.amazon.smithy.model.Model model,
            SymbolProvider symbolProvider,
            ServiceShape service,
            OperationShape operation,
            OperationIndex operationIndex
    ) {
        var opSymbol = symbolProvider.toSymbol(operation);
        var opName = operation.getId().getName(service);

        // Get HTTP trait if present
        var httpTrait = operation.getTrait(HttpTrait.class).orElse(null);
        String httpMethod = httpTrait != null ? httpTrait.getMethod() : "POST";
        String httpPath = httpTrait != null ? httpTrait.getUri().toString() : "/";

        // Get input/output shape names for schema references
        var inputShape = operationIndex.expectInputShape(operation);
        var outputShape = operationIndex.expectOutputShape(operation);
        var inputName = inputShape.getId().getName(service);
        var outputName = outputShape.getId().getName(service);

        // Add require for types module
        var serviceNs = LuaSymbolProvider.getServiceNamespace(service);
        writer.addRequire("types", serviceNs + ".types");

        writer.block("function Client:" + opSymbol.getName() + "(input, options)", () -> {
            writer.write("return self:invokeOperation(input, {");
            writer.indent();
            writer.write("name = $S,", opName);
            writer.write("input_schema = types.$L,", inputName);
            writer.write("output_schema = types.$L,", outputName);
            writer.write("http_method = $S,", httpMethod);
            writer.write("http_path = $S,", httpPath);
            writer.dedent();
            writer.write("}, options)");
        });
    }

    @Override
    public void generateStructure(GenerateStructureDirective<LuaContext, LuaSettings> directive) {
        var shape = directive.shape();
        var context = directive.context();
        context.writerDelegator().useShapeWriter(shape, writer -> {
            writeSchema(writer, shape, context, "structure");
        });
    }

    @Override
    public void generateError(GenerateErrorDirective<LuaContext, LuaSettings> directive) {
        var shape = directive.shape();
        var context = directive.context();
        context.writerDelegator().useShapeWriter(shape, writer -> {
            writeSchema(writer, shape, context, "structure");
        });
    }

    @Override
    public void generateUnion(GenerateUnionDirective<LuaContext, LuaSettings> directive) {
        var shape = directive.shape();
        var context = directive.context();
        context.writerDelegator().useShapeWriter(shape, writer -> {
            var name = shape.getId().getName(context.service());
            var model = context.model();
            writer.write("M.$L = {", name);
            writer.indent();
            writer.write("type = \"union\",");
            if (!shape.members().isEmpty()) {
                writer.write("members = {");
                writer.indent();
                for (var member : shape.members()) {
                    writeMemberSchema(writer, member, model);
                }
                writer.dedent();
                writer.write("},");
            }
            writer.dedent();
            writer.write("}");
        });
    }

    @Override
    public void generateEnumShape(GenerateEnumDirective<LuaContext, LuaSettings> directive) {
        var shape = directive.shape().asEnumShape().orElseThrow();
        var context = directive.context();
        context.writerDelegator().useShapeWriter(shape, writer -> {
            var name = shape.getId().getName(context.service());
            writer.write("M.$L = {", name);
            writer.indent();
            for (var entry : shape.getEnumValues().entrySet()) {
                writer.write("$L = $S,", entry.getKey(), entry.getValue());
            }
            writer.dedent();
            writer.write("}");
        });
    }

    @Override
    public void generateIntEnumShape(GenerateIntEnumDirective<LuaContext, LuaSettings> directive) {
        var shape = directive.shape().asIntEnumShape().orElseThrow();
        var context = directive.context();
        context.writerDelegator().useShapeWriter(shape, writer -> {
            var name = shape.getId().getName(context.service());
            writer.write("M.$L = {", name);
            writer.indent();
            for (var entry : shape.getEnumValues().entrySet()) {
                writer.write("$L = $L,", entry.getKey(), entry.getValue());
            }
            writer.dedent();
            writer.write("}");
        });
    }

    // --- Schema generation helpers ---

    private void writeSchema(LuaWriter writer, StructureShape shape, LuaContext context, String schemaType) {
        var name = shape.getId().getName(context.service());
        var model = context.model();

        writer.write("M.$L = {", name);
        writer.indent();
        writer.write("type = $S,", schemaType);

        // Error trait
        shape.getTrait(ErrorTrait.class).ifPresent(t ->
                writer.write("error = $S,", t.getValue()));

        if (!shape.members().isEmpty()) {
            writer.write("members = {");
            writer.indent();
            for (var member : shape.members()) {
                writeMemberSchema(writer, member, model);
            }
            writer.dedent();
            writer.write("},");
        }

        writer.dedent();
        writer.write("}");
    }

    private void writeMemberSchema(LuaWriter writer, MemberShape member, software.amazon.smithy.model.Model model) {
        var target = model.expectShape(member.getTarget());
        var luaType = toLuaSchemaType(target);

        writer.write("$L = {", member.getMemberName());
        writer.indent();
        writer.write("type = $S,", luaType);

        // If the target is a list, include the member schema
        if (target.getType() == ShapeType.LIST) {
            var listMember = target.asListShape().get().getMember();
            var listTarget = model.expectShape(listMember.getTarget());
            writer.write("member_type = $S,", toLuaSchemaType(listTarget));
        }

        // If the target is a map, include key/value types
        if (target.getType() == ShapeType.MAP) {
            var mapShape = target.asMapShape().get();
            var keyTarget = model.expectShape(mapShape.getKey().getTarget());
            var valueTarget = model.expectShape(mapShape.getValue().getTarget());
            writer.write("key_type = $S,", toLuaSchemaType(keyTarget));
            writer.write("value_type = $S,", toLuaSchemaType(valueTarget));
        }

        // Collect traits relevant to serde
        var traits = new TreeMap<String, String>();
        if (member.hasTrait(RequiredTrait.class)) traits.put("required", "true");
        if (member.hasTrait(HttpLabelTrait.class)) traits.put("http_label", "true");
        member.getTrait(HttpQueryTrait.class).ifPresent(t ->
                traits.put("http_query", "\"" + t.getValue() + "\""));
        if (member.hasTrait(HttpQueryParamsTrait.class)) traits.put("http_query_params", "true");
        member.getTrait(HttpHeaderTrait.class).ifPresent(t ->
                traits.put("http_header", "\"" + t.getValue() + "\""));
        if (member.hasTrait(HttpPrefixHeadersTrait.class)) {
            var prefix = member.getTrait(HttpPrefixHeadersTrait.class).get().getValue();
            traits.put("http_prefix_headers", "\"" + prefix + "\"");
        }
        if (member.hasTrait(HttpPayloadTrait.class)) traits.put("http_payload", "true");
        if (member.hasTrait(HttpResponseCodeTrait.class)) traits.put("http_response_code", "true");
        member.getTrait(JsonNameTrait.class).ifPresent(t ->
                traits.put("json_name", "\"" + t.getValue() + "\""));
        member.getTrait(XmlNameTrait.class).ifPresent(t ->
                traits.put("xml_name", "\"" + t.getValue() + "\""));
        member.getTrait(TimestampFormatTrait.class).ifPresent(t ->
                traits.put("timestamp_format", "\"" + t.getValue() + "\""));

        if (!traits.isEmpty()) {
            writer.write("traits = {");
            writer.indent();
            for (var entry : traits.entrySet()) {
                writer.write("$L = $L,", entry.getKey(), entry.getValue());
            }
            writer.dedent();
            writer.write("},");
        }

        writer.dedent();
        writer.write("},");
    }

    private String toLuaSchemaType(Shape shape) {
        return switch (shape.getType()) {
            case STRING, ENUM -> "string";
            case BOOLEAN -> "boolean";
            case BYTE, SHORT, INTEGER, LONG, FLOAT, DOUBLE,
                 BIG_INTEGER, BIG_DECIMAL, INT_ENUM -> "number";
            case TIMESTAMP -> "timestamp";
            case BLOB -> "blob";
            case LIST -> "list";
            case MAP -> "map";
            case STRUCTURE -> "structure";
            case UNION -> "union";
            case DOCUMENT -> "document";
            default -> "any";
        };
    }
}
