package software.amazon.smithy.lua.codegen;

import java.util.ArrayList;
import java.util.List;
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
import software.amazon.smithy.model.knowledge.ServiceIndex;
import software.amazon.smithy.model.knowledge.TopDownIndex;
import software.amazon.smithy.model.node.Node;
import software.amazon.smithy.model.shapes.MemberShape;
import software.amazon.smithy.model.shapes.OperationShape;
import software.amazon.smithy.model.shapes.ServiceShape;
import software.amazon.smithy.model.shapes.Shape;
import software.amazon.smithy.model.shapes.ShapeId;
import software.amazon.smithy.model.shapes.ShapeType;
import software.amazon.smithy.model.shapes.StructureShape;
import software.amazon.smithy.model.traits.ClientOptionalTrait;
import software.amazon.smithy.model.traits.DefaultTrait;
import software.amazon.smithy.model.traits.ErrorTrait;
import software.amazon.smithy.aws.traits.protocols.Ec2QueryNameTrait;
import software.amazon.smithy.model.traits.EventHeaderTrait;
import software.amazon.smithy.model.traits.EventPayloadTrait;
import software.amazon.smithy.model.traits.HttpHeaderTrait;
import software.amazon.smithy.model.traits.HttpLabelTrait;
import software.amazon.smithy.model.traits.HttpPayloadTrait;
import software.amazon.smithy.model.traits.HttpPrefixHeadersTrait;
import software.amazon.smithy.model.traits.HttpQueryTrait;
import software.amazon.smithy.model.traits.HttpQueryParamsTrait;
import software.amazon.smithy.model.traits.HttpResponseCodeTrait;
import software.amazon.smithy.model.traits.HttpTrait;
import software.amazon.smithy.model.traits.IdempotencyTokenTrait;
import software.amazon.smithy.model.traits.JsonNameTrait;
import software.amazon.smithy.model.traits.MediaTypeTrait;
import software.amazon.smithy.model.traits.RequiredTrait;
import software.amazon.smithy.model.traits.StreamingTrait;
import software.amazon.smithy.model.traits.TimestampFormatTrait;
import software.amazon.smithy.model.traits.XmlAttributeTrait;
import software.amazon.smithy.model.traits.XmlFlattenedTrait;
import software.amazon.smithy.model.traits.XmlNameTrait;
import software.amazon.smithy.model.traits.XmlNamespaceTrait;
import software.amazon.smithy.model.traits.synthetic.OriginalShapeIdTrait;
import software.amazon.smithy.rulesengine.traits.ContextParamTrait;
import software.amazon.smithy.rulesengine.traits.EndpointRuleSetTrait;
import software.amazon.smithy.rulesengine.traits.StaticContextParamsTrait;

public final class DirectedLuaCodegen
        implements DirectedCodegen<LuaContext, LuaSettings, LuaIntegration> {

    private static final java.util.Set<String> LUA_RESERVED = java.util.Set.of(
        "and", "break", "do", "else", "elseif", "end", "false", "for",
        "function", "goto", "if", "in", "local", "nil", "not", "or",
        "repeat", "return", "then", "true", "until", "while"
    );

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
            writer.write("local M = {}");
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
            writer.write("for _, s in pairs(M) do");
            writer.write("    if type(s) == \"table\" and (s.type == \"structure\" or s.type == \"union\") then");
            writer.write("        local members = rawget(s, \"_members\")");
            writer.write("        if members then");
            writer.write("            for _, ms in pairs(members) do");
            writer.write("                if (ms.type == \"structure\" or ms.type == \"union\") and not rawget(ms, \"_target\") and ms.target_id then");
            writer.write("                    rawset(ms, \"_target\", M[ms.target_id.name])");
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

        // Generate .d.tl Teal declaration files
        TealGenerator.generate(directive.context());

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
        // client.tl is generated by TealGenerator
    }

    @Override
    public void generateStructure(GenerateStructureDirective<LuaContext, LuaSettings> directive) {
        var shape = directive.shape();
        var context = directive.context();
        context.writerDelegator().useShapeWriter(shape, writer -> {
            writeSchemaNew(writer, shape, context);
        });
    }

    @Override
    public void generateError(GenerateErrorDirective<LuaContext, LuaSettings> directive) {
        var shape = directive.shape();
        var context = directive.context();
        context.writerDelegator().useShapeWriter(shape, writer -> {
            writeSchemaNew(writer, shape, context);
        });
    }

    @Override
    public void generateUnion(GenerateUnionDirective<LuaContext, LuaSettings> directive) {
        var shape = directive.shape();
        var context = directive.context();
        context.writerDelegator().useShapeWriter(shape, writer -> {
            var name = shape.getId().getName(context.service());
            var model = context.model();
            var namespace = shape.getId().getNamespace();
            writer.write("M.$L = schema.new({", name);
            writer.indent();
            writer.write("id = id.from(_N, $S),", schemaIdName(shape));
            writer.write("type = \"union\",");
            if (!shape.members().isEmpty()) {
                writer.write("members = {");
                writer.indent();
                for (var member : shape.members()) {
                    writeMemberSchemaNew(writer, member, shape, model, context.service());
                }
                writer.dedent();
                writer.write("},");
            }
            writer.dedent();
            writer.write("})");
        });
    }

    @Override
    public void generateEnumShape(GenerateEnumDirective<LuaContext, LuaSettings> directive) {
        // Enum types are generated by TealGenerator into types.tl
    }

    @Override
    public void generateIntEnumShape(GenerateIntEnumDirective<LuaContext, LuaSettings> directive) {
        // Int enum types are generated by TealGenerator into types.tl
    }

    // --- New Schema generation helpers ---

    private void writeSchemaNew(LuaWriter writer, StructureShape shape, LuaContext context) {
        var name = shape.getId().getName(context.service());
        var model = context.model();

        // Unit shapes (backfilled no-input/no-output) reference the shared prelude instance
        if ("Unit".equals(schemaIdName(shape)) && shape.members().isEmpty()) {
            writer.write("M.$L = prelude.Unit", name);
            return;
        }

        writer.write("M.$L = schema.new({", name);
        writer.indent();
        writer.write("id = id.from(_N, $S),", schemaIdName(shape));
        writer.write("type = \"structure\",");

        // Collect structure-level traits
        writeStructTraits(writer, shape, context);

        if (!shape.members().isEmpty()) {
            writer.write("members = {");
            writer.indent();
            for (var member : shape.members()) {
                writeMemberSchemaNew(writer, member, shape, model, context.service());
            }
            writer.dedent();
            writer.write("},");
        }

        writer.dedent();
        writer.write("})");
    }

    private void writeStructTraits(LuaWriter writer, StructureShape shape, LuaContext context) {
        var traitEntries = new ArrayList<String>();
        var name = shape.getId().getName(context.service());
        var rawName = shape.getId().getName();

        shape.getTrait(ErrorTrait.class).ifPresent(t ->
                traitEntries.add("[traits.ERROR] = { value = \"" + t.getValue() + "\" }"));

        shape.getTrait(XmlNameTrait.class).ifPresent(t ->
                traitEntries.add("[traits.XML_NAME] = { name = \"" + t.getValue() + "\" }"));
        if (traitEntries.stream().noneMatch(s -> s.contains("XML_NAME")) && !rawName.equals(name)) {
            traitEntries.add("[traits.XML_NAME] = { name = \"" + rawName + "\" }");
        }

        shape.getTrait(XmlNamespaceTrait.class).ifPresent(ns -> {
            var prefix = ns.getPrefix().orElse(null);
            if (prefix != null) {
                traitEntries.add("[traits.XML_NAMESPACE] = { uri = \"" + ns.getUri() + "\", prefix = \"" + prefix + "\" }");
            } else {
                traitEntries.add("[traits.XML_NAMESPACE] = { uri = \"" + ns.getUri() + "\" }");
            }
        });

        if (!traitEntries.isEmpty()) {
            writer.write("traits = {");
            writer.indent();
            for (var entry : traitEntries) {
                writer.write("$L,", entry);
            }
            writer.dedent();
            writer.write("},");
        }
    }

    private void writeMemberSchemaNew(LuaWriter writer, MemberShape member, Shape parent,
                                      software.amazon.smithy.model.Model model, ServiceShape service) {
        var target = model.expectShape(member.getTarget());
        var memberName = member.getMemberName();
        var parentName = parent.getId().getName();

        var luaKey = LUA_RESERVED.contains(memberName) ? "[\"" + memberName + "\"]" : memberName;
        writer.write("$L = schema.new({", luaKey);
        writer.indent();
        writer.write("id = id.from(_N, $S, $S),", parentName, memberName);
        writer.write("type = $S,", toLuaSchemaType(target));
        writer.write("name = $S,", memberName);
        writer.write("target_id = $L,", targetIdExpr(target, service));

        // For structure/union targets, add a reference to the target schema
        var targetType = target.getType();
        if (targetType == ShapeType.STRUCTURE || targetType == ShapeType.UNION) {
            writer.write("target = M.$L,", target.getId().getName(service));
        }

        // List member schema
        if (target.getType() == ShapeType.LIST) {
            var listMember = target.asListShape().get().getMember();
            var listTarget = model.expectShape(listMember.getTarget());
            var listMemberRef = targetSchemaRef(listTarget, service);
            // Check if the list member has traits that need a wrapper schema
            var listMemberTraits = new ArrayList<String>();
            listMember.getTrait(XmlNameTrait.class).ifPresent(t ->
                    listMemberTraits.add("[traits.XML_NAME] = { name = \"" + t.getValue() + "\" }"));
            listMember.getTrait(XmlNamespaceTrait.class).ifPresent(ns -> {
                var p = ns.getPrefix().orElse(null);
                if (p != null) {
                    listMemberTraits.add("[traits.XML_NAMESPACE] = { uri = \"" + ns.getUri() + "\", prefix = \"" + p + "\" }");
                } else {
                    listMemberTraits.add("[traits.XML_NAMESPACE] = { uri = \"" + ns.getUri() + "\" }");
                }
            });
            if (listTarget.getType() == ShapeType.LIST) {
                // Nested list: emit inline schema
                var innerMember = listTarget.asListShape().get().getMember();
                var innerTarget = model.expectShape(innerMember.getTarget());
                writer.write("list_member = schema.new({ type = \"list\", list_member = $L }),", targetSchemaRef(innerTarget, service));
            } else if (!listMemberTraits.isEmpty()) {
                // List member with traits: wrap in schema.new
                writer.write("list_member = schema.new({ type = $S, target = $L, traits = { $L } }),",
                        toLuaSchemaType(listTarget), listMemberRef, String.join(", ", listMemberTraits));
            } else {
                writer.write("list_member = $L,", listMemberRef);
            }
        }

        // Map key/value schemas
        if (target.getType() == ShapeType.MAP) {
            var mapShape = target.asMapShape().get();
            var keyMember = mapShape.getKey();
            var valueMember = mapShape.getValue();
            var keyTarget = model.expectShape(keyMember.getTarget());
            var valueTarget = model.expectShape(valueMember.getTarget());
            // Key
            var keyTraits = new ArrayList<String>();
            keyMember.getTrait(XmlNameTrait.class).ifPresent(t ->
                    keyTraits.add("[traits.XML_NAME] = { name = \"" + t.getValue() + "\" }"));
            keyMember.getTrait(XmlNamespaceTrait.class).ifPresent(ns -> {
                var p = ns.getPrefix().orElse(null);
                if (p != null) {
                    keyTraits.add("[traits.XML_NAMESPACE] = { uri = \"" + ns.getUri() + "\", prefix = \"" + p + "\" }");
                } else {
                    keyTraits.add("[traits.XML_NAMESPACE] = { uri = \"" + ns.getUri() + "\" }");
                }
            });
            if (!keyTraits.isEmpty()) {
                writer.write("map_key = schema.new({ type = $S, traits = { $L } }),",
                        toLuaSchemaType(keyTarget), String.join(", ", keyTraits));
            } else {
                writer.write("map_key = $L,", targetSchemaRef(keyTarget, service));
            }
            // Value
            var valueTraits = new ArrayList<String>();
            valueMember.getTrait(XmlNameTrait.class).ifPresent(t ->
                    valueTraits.add("[traits.XML_NAME] = { name = \"" + t.getValue() + "\" }"));
            valueMember.getTrait(XmlNamespaceTrait.class).ifPresent(ns -> {
                var p = ns.getPrefix().orElse(null);
                if (p != null) {
                    valueTraits.add("[traits.XML_NAMESPACE] = { uri = \"" + ns.getUri() + "\", prefix = \"" + p + "\" }");
                } else {
                    valueTraits.add("[traits.XML_NAMESPACE] = { uri = \"" + ns.getUri() + "\" }");
                }
            });
            if (valueTarget.getType() == ShapeType.MAP) {
                // Nested map: emit inline schema with inner key/value traits
                var innerMap = valueTarget.asMapShape().get();
                var innerKeyMember = innerMap.getKey();
                var innerValueMember = innerMap.getValue();
                var innerKeyTarget = model.expectShape(innerKeyMember.getTarget());
                var innerValueTarget = model.expectShape(innerValueMember.getTarget());
                var innerKeyRef = targetSchemaRef(innerKeyTarget, service);
                var innerValueRef = targetSchemaRef(innerValueTarget, service);
                // Check for xmlName on inner key/value
                var innerKeyXmlName = innerKeyMember.getTrait(XmlNameTrait.class);
                var innerValueXmlName = innerValueMember.getTrait(XmlNameTrait.class);
                if (innerKeyXmlName.isPresent() || innerValueXmlName.isPresent()) {
                    var innerKeyStr = innerKeyXmlName.isPresent()
                            ? "schema.new({ type = \"" + toLuaSchemaType(innerKeyTarget) + "\", traits = { [traits.XML_NAME] = { name = \"" + innerKeyXmlName.get().getValue() + "\" } } })"
                            : innerKeyRef;
                    var innerValueStr = innerValueXmlName.isPresent()
                            ? "schema.new({ type = \"" + toLuaSchemaType(innerValueTarget) + "\", traits = { [traits.XML_NAME] = { name = \"" + innerValueXmlName.get().getValue() + "\" } } })"
                            : innerValueRef;
                    writer.write("map_value = schema.new({ type = \"map\", map_key = $L, map_value = $L }),",
                            innerKeyStr, innerValueStr);
                } else {
                    writer.write("map_value = schema.new({ type = \"map\", map_key = $L, map_value = $L }),",
                            innerKeyRef, innerValueRef);
                }
            } else if (valueTarget.getType() == ShapeType.LIST) {
                // Nested list as map value: emit inline list schema
                var innerListMember = valueTarget.asListShape().get().getMember();
                var innerListTarget = model.expectShape(innerListMember.getTarget());
                writer.write("map_value = schema.new({ type = \"list\", list_member = $L }),",
                        targetSchemaRef(innerListTarget, service));
            } else if (!valueTraits.isEmpty()) {
                writer.write("map_value = schema.new({ type = $S, target = $L, traits = { $L } }),",
                        toLuaSchemaType(valueTarget), targetSchemaRef(valueTarget, service), String.join(", ", valueTraits));
            } else {
                writer.write("map_value = $L,", targetSchemaRef(valueTarget, service));
            }
        }

        // Collect effective traits (merged: target + member)
        var effectiveTraits = collectTraitsNew(member, model);
        // Collect direct traits (member-only)
        var directTraits = collectDirectTraitsNew(member);

        if (!effectiveTraits.isEmpty()) {
            writer.write("traits = {");
            writer.indent();
            for (var entry : effectiveTraits) {
                writer.write("$L,", entry);
            }
            writer.dedent();
            writer.write("},");
        }

        if (!directTraits.isEmpty() && !directTraits.equals(effectiveTraits)) {
            writer.write("direct_traits = {");
            writer.indent();
            for (var entry : directTraits) {
                writer.write("$L,", entry);
            }
            writer.dedent();
            writer.write("},");
        }

        writer.dedent();
        writer.write("}),");
    }

    private String targetIdExpr(Shape target, ServiceShape service) {
        var targetType = target.getType();
        if (targetType == ShapeType.STRUCTURE || targetType == ShapeType.UNION) {
            // Use id.from() directly to avoid forward reference issues with recursive shapes
            return "id.from(_N, \"" + target.getId().getName() + "\")";
        }
        return preludeIdExpr(target);
    }

    private String targetSchemaRef(Shape target, ServiceShape service) {
        var targetType = target.getType();
        if (targetType == ShapeType.STRUCTURE || targetType == ShapeType.UNION
                || targetType == ShapeType.LIST || targetType == ShapeType.MAP) {
            return "M." + target.getId().getName(service);
        }
        return preludeSchemaRef(target);
    }

    private String schemaIdName(Shape shape) {
        return shape.getTrait(OriginalShapeIdTrait.class)
                .map(t -> t.getOriginalId().getName())
                .orElse(shape.getId().getName());
    }

    private String preludeIdExpr(Shape target) {
        return "prelude." + preludeName(target) + ".id";
    }

    private String preludeSchemaRef(Shape target) {
        return "prelude." + preludeName(target);
    }

    private String preludeName(Shape target) {
        return switch (target.getType()) {
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
            case DOCUMENT -> "Document";
            default -> "Document";
        };
    }

    private List<String> collectTraitsNew(MemberShape member, software.amazon.smithy.model.Model model) {
        var entries = new ArrayList<String>();
        var target = model.expectShape(member.getTarget());

        // Member traits
        addMemberTraitEntries(entries, member);

        // Target traits that merge into effective view
        if (!member.hasTrait(TimestampFormatTrait.class)) {
            target.getTrait(TimestampFormatTrait.class).ifPresent(t ->
                    entries.add("[traits.TIMESTAMP_FORMAT] = { format = \"" + t.getValue() + "\" }"));
        }
        target.getTrait(MediaTypeTrait.class).ifPresent(t ->
                entries.add("[traits.MEDIA_TYPE] = { value = \"" + t.getValue() + "\" }"));
        target.getTrait(StreamingTrait.class).ifPresent(t ->
                entries.add("[traits.STREAMING] = {}"));

        return entries;
    }

    private List<String> collectDirectTraitsNew(MemberShape member) {
        var entries = new ArrayList<String>();
        addMemberTraitEntries(entries, member);
        return entries;
    }

    private void addMemberTraitEntries(List<String> entries, MemberShape member) {
        if (member.hasTrait(RequiredTrait.class))
            entries.add("[traits.REQUIRED] = {}");
        if (!member.hasTrait(ClientOptionalTrait.class)) {
            member.getTrait(DefaultTrait.class).ifPresent(t ->
                    entries.add("[traits.DEFAULT] = { value = " + nodeToLua(t.toNode()) + " }"));
        }
        if (member.hasTrait(HttpLabelTrait.class))
            entries.add("[traits.HTTP_LABEL] = {}");
        member.getTrait(HttpQueryTrait.class).ifPresent(t ->
                entries.add("[traits.HTTP_QUERY] = { name = \"" + t.getValue() + "\" }"));
        if (member.hasTrait(HttpQueryParamsTrait.class))
            entries.add("[traits.HTTP_QUERY_PARAMS] = {}");
        member.getTrait(HttpHeaderTrait.class).ifPresent(t ->
                entries.add("[traits.HTTP_HEADER] = { name = \"" + t.getValue() + "\" }"));
        if (member.hasTrait(HttpPrefixHeadersTrait.class)) {
            var prefix = member.getTrait(HttpPrefixHeadersTrait.class).get().getValue();
            entries.add("[traits.HTTP_PREFIX_HEADERS] = { prefix = \"" + prefix + "\" }");
        }
        if (member.hasTrait(HttpPayloadTrait.class))
            entries.add("[traits.HTTP_PAYLOAD] = {}");
        if (member.hasTrait(HttpResponseCodeTrait.class))
            entries.add("[traits.HTTP_RESPONSE_CODE] = {}");
        member.getTrait(JsonNameTrait.class).ifPresent(t ->
                entries.add("[traits.JSON_NAME] = { name = \"" + t.getValue() + "\" }"));
        member.getTrait(XmlNameTrait.class).ifPresent(t ->
                entries.add("[traits.XML_NAME] = { name = \"" + t.getValue() + "\" }"));
        if (member.hasTrait(XmlAttributeTrait.class))
            entries.add("[traits.XML_ATTRIBUTE] = {}");
        if (member.hasTrait(XmlFlattenedTrait.class))
            entries.add("[traits.XML_FLATTENED] = {}");
        member.getTrait(XmlNamespaceTrait.class).ifPresent(ns -> {
            var prefix = ns.getPrefix().orElse(null);
            if (prefix != null) {
                entries.add("[traits.XML_NAMESPACE] = { uri = \"" + ns.getUri() + "\", prefix = \"" + prefix + "\" }");
            } else {
                entries.add("[traits.XML_NAMESPACE] = { uri = \"" + ns.getUri() + "\" }");
            }
        });
        member.getTrait(TimestampFormatTrait.class).ifPresent(t ->
                entries.add("[traits.TIMESTAMP_FORMAT] = { format = \"" + t.getValue() + "\" }"));
        if (member.hasTrait(IdempotencyTokenTrait.class))
            entries.add("[traits.IDEMPOTENCY_TOKEN] = {}");
        if (member.hasTrait(EventHeaderTrait.class))
            entries.add("[traits.EVENT_HEADER] = {}");
        if (member.hasTrait(EventPayloadTrait.class))
            entries.add("[traits.EVENT_PAYLOAD] = {}");
        member.getTrait(Ec2QueryNameTrait.class).ifPresent(t ->
                entries.add("[traits.EC2_QUERY_NAME] = { name = \"" + t.getValue() + "\" }"));
    }

    private static String nodeToLua(Node node) {
        if (node.isNullNode()) return "nil";
        if (node.isBooleanNode()) return node.expectBooleanNode().getValue() ? "true" : "false";
        if (node.isNumberNode()) {
            var num = node.expectNumberNode().getValue();
            if (num.doubleValue() == num.longValue()) {
                return String.valueOf(num.longValue());
            }
            return num.toString();
        }
        if (node.isStringNode()) return "\"" + node.expectStringNode().getValue()
                .replace("\\", "\\\\").replace("\"", "\\\"") + "\"";
        if (node.isArrayNode()) return "{}";
        if (node.isObjectNode()) return "{}";
        return "nil";
    }

    private String toLuaSchemaType(Shape shape) {
        return switch (shape.getType()) {
            case STRING, ENUM -> "string";
            case BOOLEAN -> "boolean";
            case BYTE -> "byte";
            case SHORT -> "short";
            case INTEGER -> "integer";
            case LONG -> "long";
            case FLOAT -> "float";
            case DOUBLE -> "double";
            case BIG_INTEGER, BIG_DECIMAL, INT_ENUM -> "number";
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
