package software.amazon.smithy.lua.codegen;

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
import software.amazon.smithy.model.knowledge.ServiceIndex;
import software.amazon.smithy.model.knowledge.TopDownIndex;
import software.amazon.smithy.model.shapes.ServiceShape;
import software.amazon.smithy.model.shapes.Shape;
import software.amazon.smithy.model.shapes.ShapeType;
import software.amazon.smithy.model.traits.HttpTrait;
import software.amazon.smithy.model.traits.StreamingTrait;
import software.amazon.smithy.rulesengine.traits.ContextParamTrait;
import software.amazon.smithy.rulesengine.traits.StaticContextParamsTrait;

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
        var serviceNs = LuaSymbolProvider.getServiceNamespace(directive.context().service());
        var service = directive.context().service();
        var namespace = service.getId().getNamespace();

        // Write module header to types.tl
        var typesFile = serviceNs + "/types.tl";
        directive.context().writerDelegator().useFileWriter(typesFile, serviceNs, writer -> {
            writer.write("local record M");
            writer.indent();
        });

        // Write module header to schemas.tl
        var schemasFile = serviceNs + "/schemas.tl";
        directive.context().writerDelegator().useFileWriter(schemasFile, serviceNs, writer -> {
            writer.write("local id = require(\"smithy.shape_id\")");
            writer.write("local schema = require(\"smithy.schema\")");
            writer.write("local prelude = require(\"smithy.prelude\")");
            writer.write("local traits = require(\"smithy.traits\")");
            writer.write("");
            writer.write("local _N = $S", namespace);
            writer.write("");
            writer.write("local M: {string:any} = {}");
            writer.write("");

            // Generate list and map schemas before structures (they may be referenced as map_value/list_member)
            var model = directive.model();
            var walker = new software.amazon.smithy.model.neighbor.Walker(model);
            var shapes = walker.walkShapes(service);
            for (var shape : shapes) {
                if (shape.getType() == ShapeType.LIST) {
                    var listShape = shape.asListShape().get();
                    var name = listShape.getId().getName(service);
                    var memberTarget = model.expectShape(listShape.getMember().getTarget());
                    writer.write("M.$L = schema.new({ type = \"list\", list_member = $L })",
                            name, targetSchemaRef(memberTarget, service));
                    writer.write("");
                } else if (shape.getType() == ShapeType.MAP) {
                    var mapShape = shape.asMapShape().get();
                    var name = mapShape.getId().getName(service);
                    var keyTarget = model.expectShape(mapShape.getKey().getTarget());
                    var valueTarget = model.expectShape(mapShape.getValue().getTarget());
                    writer.write("M.$L = schema.new({ type = \"map\", map_key = $L, map_value = $L })",
                            name, targetSchemaRef(keyTarget, service), targetSchemaRef(valueTarget, service));
                    writer.write("");
                }
            }
        });
    }

    @Override
    public void customizeBeforeIntegrations(CustomizeDirective<LuaContext, LuaSettings> directive) {
        var serviceNs = LuaSymbolProvider.getServiceNamespace(directive.context().service());
        var service = directive.context().service();

        // Write module footer to schemas.tl (with forward reference fixup + service/operation schemas)
        var schemasFile = serviceNs + "/schemas.tl";
        var model = directive.model();
        directive.context().writerDelegator().useFileWriter(schemasFile, serviceNs, writer -> {
            writer.write("");
            writer.write("-- Fix forward references for recursive schemas");
            writer.write("for _, _s in pairs(M) do");
            writer.write("    local s = _s as {string:any}");
            writer.write("    if type(s) == \"table\" and (s.type == \"structure\" or s.type == \"union\") then");
            writer.write("        local members = rawget(s, \"_members\") as {string:{string:any}}");
            writer.write("        if members then");
            writer.write("            for _, ms in pairs(members) do");
            writer.write("                if (ms.type == \"structure\" or ms.type == \"union\") and not rawget(ms as {string:any}, \"_target\") and ms.target_id then");
            writer.write("                    rawset(ms as {string:any}, \"_target\", M[(ms.target_id as {string:string}).name])");
            writer.write("                end");
            writer.write("            end");
            writer.write("        end");
            writer.write("    end");
            writer.write("end");
            writer.write("");

            // Emit service schema
            var namespace = service.getId().getNamespace();
            writer.write("M.Service = schema.service({");
            writer.indent();
            writer.write("id = id.from($S, $S),", namespace, service.getId().getName());
            writer.write("version = $S,", service.getVersion());
            // Service-level auth trait
            var serviceIndex = ServiceIndex.of(model);
            var serviceAuth = serviceIndex.getEffectiveAuthSchemes(service);
            if (!serviceAuth.isEmpty()) {
                writer.write("traits = {");
                writer.indent();
                writer.write("[traits.AUTH] = {");
                writer.indent();
                for (var schemeId : serviceAuth.keySet()) {
                    writer.write("{ scheme_id = $S },", schemeId.toString());
                }
                writer.dedent();
                writer.write("},");
                writer.dedent();
                writer.write("},");
            } else {
                writer.write("traits = {},");
            }
            writer.dedent();
            writer.write("})");
            writer.write("");

            // Emit operation schemas
            var topDown = TopDownIndex.of(model);
            var operations = topDown.getContainedOperations(service);
            var operationIndex = OperationIndex.of(model);
            for (var operation : operations) {
                var opName = operation.getId().getName(service);
                var inputShape = operationIndex.expectInputShape(operation);
                var outputShape = operationIndex.expectOutputShape(operation);
                var inputName = inputShape.getId().getName(service);
                var outputName = outputShape.getId().getName(service);

                // HTTP trait
                var httpTrait = operation.getTrait(HttpTrait.class).orElse(null);

                // Effective auth
                var effectiveAuth = serviceIndex.getEffectiveAuthSchemes(
                        service, operation, ServiceIndex.AuthSchemeMode.NO_AUTH_AWARE);

                // Context params from @contextParam on input members
                var contextParams = new TreeMap<String, String>();
                for (var member : inputShape.members()) {
                    member.getTrait(ContextParamTrait.class).ifPresent(t ->
                            contextParams.put(t.getName(), member.getMemberName()));
                }

                // Event stream
                String eventStreamUnion = null;
                for (var member : outputShape.members()) {
                    var target = model.expectShape(member.getTarget());
                    if (target.hasTrait(StreamingTrait.class) && target.isUnionShape()) {
                        eventStreamUnion = target.getId().getName(service);
                        break;
                    }
                }

                writer.write("M.$L = schema.operation({", opName);
                writer.indent();
                writer.write("id = id.from($S, $S),", namespace, operation.getId().getName());
                writer.write("input = M.$L,", inputName);
                writer.write("output = M.$L,", outputName);
                writer.write("traits = {");
                writer.indent();
                if (httpTrait != null) {
                    writer.write("[traits.HTTP] = { method = $S, path = $S },",
                            httpTrait.getMethod(), httpTrait.getUri().toString());
                }
                if (!effectiveAuth.isEmpty()) {
                    writer.write("[traits.AUTH] = {");
                    writer.indent();
                    for (var schemeId : effectiveAuth.keySet()) {
                        writer.write("{ scheme_id = $S },", schemeId.toString());
                    }
                    writer.dedent();
                    writer.write("},");
                }
                if (!contextParams.isEmpty()) {
                    writer.write("[traits.CONTEXT_PARAMS] = {");
                    writer.indent();
                    for (var entry : contextParams.entrySet()) {
                        writer.write("$L = $S,", entry.getKey(), entry.getValue());
                    }
                    writer.dedent();
                    writer.write("},");
                }
                var staticContextParams = operation.getTrait(StaticContextParamsTrait.class).orElse(null);
                if (staticContextParams != null && !staticContextParams.getParameters().isEmpty()) {
                    writer.write("[traits.STATIC_CONTEXT_PARAMS] = {");
                    writer.indent();
                    for (var entry : staticContextParams.getParameters().entrySet()) {
                        var node = entry.getValue().getValue();
                        if (node.isBooleanNode()) {
                            writer.write("$L = { value = $L },", entry.getKey(), node.expectBooleanNode().getValue());
                        } else if (node.isStringNode()) {
                            writer.write("$L = { value = $S },", entry.getKey(), node.expectStringNode().getValue());
                        }
                    }
                    writer.dedent();
                    writer.write("},");
                }
                if (eventStreamUnion != null) {
                    writer.write("[traits.EVENT_STREAM] = M.$L,", eventStreamUnion);
                }
                writer.dedent();
                writer.write("},");
                writer.dedent();
                writer.write("})");
                writer.write("");
            }

            writer.write("return M");
        });

        // Close types.tl module
        var typesFile = serviceNs + "/types.tl";
        directive.context().writerDelegator().useFileWriter(typesFile, serviceNs, writer -> {
            writer.dedent();
            writer.write("end");
            writer.write("");
            writer.write("return M");
        });

        // Generate client.tl
        ClientGenerator.generate(directive.context());

        // Generate endpoint_rules.lua from endpointRuleSet trait
        EndpointRulesetGenerator.generate(directive.context());
    }

    @Override
    public void customizeAfterIntegrations(CustomizeDirective<LuaContext, LuaSettings> directive) {
        var serviceId = directive.context().service().getId();
        for (var integration : directive.context().integrations()) {
            if (!integration.forService(serviceId)) {
                continue;
            }
            integration.writeAdditionalFiles(directive.context());
        }
    }

    @Override
    public void generateService(GenerateServiceDirective<LuaContext, LuaSettings> directive) {
        // client.tl is generated by ClientGenerator in customizeBeforeIntegrations
    }

    @Override
    public void generateStructure(GenerateStructureDirective<LuaContext, LuaSettings> directive) {
        var gen = new StructureGenerator(directive.context(), directive.shape());
        var serviceNs = LuaSymbolProvider.getServiceNamespace(directive.context().service());
        directive.context().writerDelegator().useShapeWriter(directive.shape(), gen::writeSchema);
        directive.context().writerDelegator().useFileWriter(serviceNs + "/types.tl", serviceNs, gen::writeType);
    }

    @Override
    public void generateError(GenerateErrorDirective<LuaContext, LuaSettings> directive) {
        var gen = new StructureGenerator(directive.context(), directive.shape());
        var serviceNs = LuaSymbolProvider.getServiceNamespace(directive.context().service());
        directive.context().writerDelegator().useShapeWriter(directive.shape(), gen::writeSchema);
        directive.context().writerDelegator().useFileWriter(serviceNs + "/types.tl", serviceNs, gen::writeType);
    }

    @Override
    public void generateUnion(GenerateUnionDirective<LuaContext, LuaSettings> directive) {
        var gen = new StructureGenerator(directive.context(), directive.shape());
        var serviceNs = LuaSymbolProvider.getServiceNamespace(directive.context().service());
        directive.context().writerDelegator().useShapeWriter(directive.shape(), gen::writeSchema);
        directive.context().writerDelegator().useFileWriter(serviceNs + "/types.tl", serviceNs, gen::writeType);
    }

    @Override
    public void generateEnumShape(GenerateEnumDirective<LuaContext, LuaSettings> directive) {
        var context = directive.context();
        var serviceNs = LuaSymbolProvider.getServiceNamespace(context.service());
        context.writerDelegator().useFileWriter(serviceNs + "/types.tl", serviceNs, writer -> {
            EnumGenerator.writeEnum(writer, directive.shape(), context);
        });
    }

    @Override
    public void generateIntEnumShape(GenerateIntEnumDirective<LuaContext, LuaSettings> directive) {
        var context = directive.context();
        var serviceNs = LuaSymbolProvider.getServiceNamespace(context.service());
        context.writerDelegator().useFileWriter(serviceNs + "/types.tl", serviceNs, writer -> {
            EnumGenerator.writeIntEnum(writer, directive.shape(), context);
        });
    }

    private static String targetSchemaRef(Shape target, ServiceShape service) {
        var targetType = target.getType();
        if (targetType == ShapeType.STRUCTURE || targetType == ShapeType.UNION
                || targetType == ShapeType.LIST || targetType == ShapeType.MAP) {
            return "M." + target.getId().getName(service);
        }
        return "prelude." + switch (target.getType()) {
            case STRING, ENUM -> "String";
            case BOOLEAN -> "Boolean";
            case BYTE -> "Byte";
            case SHORT -> "Short";
            case INTEGER, INT_ENUM -> "Integer";
            case LONG -> "Long";
            case FLOAT -> "Float";
            case DOUBLE -> "Double";
            case BIG_INTEGER -> "Integer";
            case BIG_DECIMAL -> "Double";
            case TIMESTAMP -> "Timestamp";
            case BLOB -> "Blob";
            default -> "Document";
        };
    }
}
