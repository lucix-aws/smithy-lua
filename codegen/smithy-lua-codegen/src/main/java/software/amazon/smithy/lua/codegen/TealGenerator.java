package software.amazon.smithy.lua.codegen;

import java.util.Collection;
import java.util.Locale;
import software.amazon.smithy.codegen.core.SymbolProvider;
import software.amazon.smithy.codegen.core.WriterDelegator;
import software.amazon.smithy.model.Model;
import software.amazon.smithy.model.knowledge.OperationIndex;
import software.amazon.smithy.model.knowledge.TopDownIndex;
import software.amazon.smithy.model.shapes.EnumShape;
import software.amazon.smithy.model.shapes.IntEnumShape;
import software.amazon.smithy.model.shapes.MemberShape;
import software.amazon.smithy.model.shapes.OperationShape;
import software.amazon.smithy.model.shapes.ServiceShape;
import software.amazon.smithy.model.shapes.Shape;
import software.amazon.smithy.model.shapes.ShapeType;
import software.amazon.smithy.model.shapes.StructureShape;
import software.amazon.smithy.model.shapes.UnionShape;
import software.amazon.smithy.model.traits.DocumentationTrait;
import software.amazon.smithy.model.traits.HttpPayloadTrait;
import software.amazon.smithy.model.traits.RequiredTrait;
import software.amazon.smithy.model.traits.StreamingTrait;

/**
 * Generates Teal .d.tl declaration files alongside .lua files.
 */
final class TealGenerator {

    static void generate(LuaContext context) {
        var model = context.model();
        var service = context.service();
        var serviceNs = LuaSymbolProvider.getServiceNamespace(service);
        var delegator = context.writerDelegator();
        var symbolProvider = context.symbolProvider();

        generateTypesDecl(delegator, model, service, serviceNs, symbolProvider);
        generateClient(context, delegator, model, service, serviceNs, symbolProvider);
    }

    private static void generateTypesDecl(
            WriterDelegator<LuaWriter> delegator,
            Model model,
            ServiceShape service,
            String serviceNs,
            SymbolProvider symbolProvider
    ) {
        var file = serviceNs + "/types.tl";
        delegator.useFileWriter(file, serviceNs, writer -> {
            var topDown = TopDownIndex.of(model);
            var operationIndex = OperationIndex.of(model);

            writer.write("local record M");
            writer.indent();

            // Walk all shapes reachable from the service
            var walker = new software.amazon.smithy.model.neighbor.Walker(model);
            var allShapes = walker.walkShapes(service);
            var emittedRecords = new java.util.HashSet<String>();

            // Generate records for all structures and unions
            allShapes.stream()
                .filter(s -> s.getType() == ShapeType.STRUCTURE || s.getType() == ShapeType.UNION)
                .sorted((a, b) -> a.getId().getName(service).compareTo(b.getId().getName(service)))
                .forEach(shape -> {
                    var name = shape.getId().getName(service);
                    if (emittedRecords.add(name)) {
                        writeNestedRecordFromShape(writer, shape, service, model);
                        writer.write("");
                    }
                });

            // Generate enum types inside M
            model.shapes(EnumShape.class)
                .filter(shape -> isInService(shape, service, model))
                .sorted((a, b) -> a.getId().getName(service).compareTo(b.getId().getName(service)))
                .forEach(shape -> {
                    writeNestedEnum(writer, shape, service);
                    writer.write("");
                });
            model.shapes(IntEnumShape.class)
                .filter(shape -> isInService(shape, service, model))
                .sorted((a, b) -> a.getId().getName(service).compareTo(b.getId().getName(service)))
                .forEach(shape -> {
                    writeIntEnumType(writer, shape, service);
                    writer.write("");
                });

            writer.dedent();
            writer.write("end");
            writer.write("");
            writer.write("return M");
        });
    }

    private static void generateClient(
            LuaContext context,
            WriterDelegator<LuaWriter> delegator,
            Model model,
            ServiceShape service,
            String serviceNs,
            SymbolProvider symbolProvider
    ) {
        var file = serviceNs + "/client.tl";
        delegator.useFileWriter(file, serviceNs, writer -> {
            var topDown = TopDownIndex.of(model);
            var operationIndex = OperationIndex.of(model);

            // Collect config resolvers from integrations
            var configResolvers = new java.util.ArrayList<ConfigResolver>();
            var configFinalizers = new java.util.ArrayList<ConfigResolver>();
            for (var integration : context.integrations()) {
                if (!integration.forService(service.getId())) continue;
                configResolvers.addAll(integration.getConfigResolvers(context));
                configFinalizers.addAll(integration.getConfigFinalizers(context));
            }

            // Determine protocol
            String protocolAlias = null;
            String protocolRequire = null;
            String protocolExpr = null;
            for (var traitId : service.getAllTraits().keySet()) {
                var n = traitId.toString();
                if (n.equals("aws.protocols#awsJson1_0")) {
                    protocolAlias = "awsjson_protocol"; protocolRequire = "smithy.protocol.awsjson";
                    protocolExpr = "awsjson_protocol.new({ version = \"1.0\", service_id = c.service_id })";
                } else if (n.equals("aws.protocols#awsJson1_1")) {
                    protocolAlias = "awsjson_protocol"; protocolRequire = "smithy.protocol.awsjson";
                    protocolExpr = "awsjson_protocol.new({ version = \"1.1\", service_id = c.service_id })";
                } else if (n.equals("aws.protocols#restJson1")) {
                    protocolAlias = "restjson_protocol"; protocolRequire = "smithy.protocol.restjson";
                    protocolExpr = "restjson_protocol.new()";
                } else if (n.equals("aws.protocols#restXml")) {
                    protocolAlias = "restxml_protocol"; protocolRequire = "smithy.protocol.restxml";
                    var noWrap = service.getAllTraits().get(traitId).toNode().asObjectNode()
                            .flatMap(o -> o.getBooleanMember("noErrorWrapping")).map(b -> b.getValue()).orElse(false);
                    protocolExpr = noWrap ? "restxml_protocol.new({ no_error_wrapping = true })" : "restxml_protocol.new()";
                } else if (n.equals("aws.protocols#awsQuery")) {
                    protocolAlias = "query_protocol"; protocolRequire = "smithy.protocol.awsquery";
                    protocolExpr = "query_protocol.new(\"awsQuery\")";
                } else if (n.equals("aws.protocols#ec2Query")) {
                    protocolAlias = "query_protocol"; protocolRequire = "smithy.protocol.ec2query";
                    protocolExpr = "query_protocol.new(\"ec2Query\")";
                } else if (n.equals("smithy.protocols#rpcv2Cbor")) {
                    protocolAlias = "rpcv2_protocol"; protocolRequire = "smithy.protocol.rpcv2";
                    protocolExpr = "rpcv2_protocol.new_cbor()";
                }
            }

            String signingName = service.getId().getName().toLowerCase(java.util.Locale.US);
            var sigv4 = service.getTrait(software.amazon.smithy.aws.traits.auth.SigV4Trait.class);
            if (sigv4.isPresent()) signingName = sigv4.get().getName();

            // Requires (no type annotations - lets teal treat unknown modules permissively)
            writer.write("-- Code generated by lua-client-codegen. DO NOT EDIT.");
            writer.write("");
            writer.write("local async = require(\"smithy.async\")");
            writer.write("local base_client = require(\"smithy.client\")");
            writer.write("local defaults = require(\"smithy.defaults\")");
            writer.write("local endpoint = require(\"smithy.endpoint\")");
            writer.write("local endpoint_rules = require(\"$L.endpoint_rules\")", serviceNs);
            if (protocolRequire != null) {
                writer.write("local $L = require(\"$L\")", protocolAlias, protocolRequire);
            }
            writer.write("local schemas = require(\"$L.schemas\")", serviceNs);
            writer.write("local traits = require(\"smithy.traits\")");
            writer.write("local types = require(\"$L.types\")", serviceNs);
            var emittedAliases = new java.util.HashSet<String>();
            for (var resolver : configResolvers) {
                if (emittedAliases.add(resolver.requireAlias())) {
                    writer.write("local $L = require(\"$L\")", resolver.requireAlias(), resolver.requirePath());
                }
            }
            for (var finalizer : configFinalizers) {
                if (emittedAliases.add(finalizer.requireAlias())) {
                    writer.write("local $L = require(\"$L\")", finalizer.requireAlias(), finalizer.requirePath());
                }
            }
            writer.write("");

            // Client record
            writer.write("local record Client");
            writer.indent();
            writer.write("config: {string:any}");
            writer.write("invokeOperation: function(Client, any, any, any, any): async.Operation<any>");
            for (var operation : topDown.getContainedOperations(service)) {
                var opName = symbolProvider.toSymbol(operation).getName();
                var inputName = operationIndex.expectInputShape(operation).getId().getName(service);
                var outputName = operationIndex.expectOutputShape(operation).getId().getName(service);
                writer.write("$L: function(Client, types.$L, any): async.Operation<types.$L>",
                        opName, inputName, outputName);
            }
            writer.dedent();
            writer.write("end");
            writer.write("");

            writer.write("local record M");
            writer.indent();
            writer.write("new: function(cfg?: {string:any}): Client");
            writer.dedent();
            writer.write("end");
            writer.write("");

            // Metatable
            writer.write("local Client_mt: metatable<Client> = { __index = {} as Client }");
            writer.write("local C = Client_mt.__index as Client");
            writer.write("C.invokeOperation = base_client.invokeOperation");
            writer.write("");

            // Constructor
            writer.write("function M.new(cfg?: {string:any}): Client");
            writer.indent();
            writer.write("local c = cfg or {}");
            writer.write("c.service_id = $S", service.getId().getName());
            if (protocolExpr != null) {
                writer.write("if not c.protocol then c.protocol = $L end", protocolExpr);
            }
            writer.write("if not c.endpoint_provider then");
            writer.indent();
            writer.write("c.endpoint_provider = function(params)");
            writer.indent();
            writer.write("return endpoint.resolve(endpoint_rules, params)");
            writer.dedent();
            writer.write("end");
            writer.dedent();
            writer.write("end");
            writer.write("if not c.auth_scheme_resolver then");
            writer.indent();
            writer.write("c.auth_scheme_resolver = function(_service, operation)");
            writer.indent();
            writer.write("local auth_trait = operation:trait(traits.AUTH) or _service:trait(traits.AUTH)");
            writer.write("local options = {}");
            writer.write("for _, scheme in ipairs(auth_trait or {}) do");
            writer.indent();
            writer.write("local scheme_id = scheme.scheme_id or scheme");
            writer.write("if scheme_id == \"aws.auth#sigv4\" or scheme_id == \"aws.auth#sigv4a\" then");
            writer.indent();
            writer.write("options[#options + 1] = { scheme_id = scheme_id, signer_properties = { signing_name = $S, signing_region = c.region } }", signingName);
            writer.dedent();
            writer.write("else");
            writer.indent();
            writer.write("options[#options + 1] = { scheme_id = scheme_id }");
            writer.dedent();
            writer.write("end");
            writer.dedent();
            writer.write("end");
            writer.write("return options");
            writer.dedent();
            writer.write("end");
            writer.dedent();
            writer.write("end");
            writer.write("defaults.resolve_auth_schemes(c)");
            writer.write("defaults.resolve_identity_resolvers(c)");
            writer.write("defaults.resolve_http_client(c)");
            writer.write("defaults.resolve_retry_strategy(c)");
            for (var resolver : configResolvers) {
                writer.write(resolver.functionCall().replace("cfg", "c"));
            }
            writer.write("local self = setmetatable(base_client.new(c) as Client, Client_mt)");
            for (var finalizer : configFinalizers) {
                writer.write(finalizer.functionCall().replace("cfg", "c"));
            }
            writer.write("return self");
            writer.dedent();
            writer.write("end");
            writer.write("");

            // Operation methods
            for (var operation : topDown.getContainedOperations(service)) {
                var opName = symbolProvider.toSymbol(operation).getName();
                var opSchemaName = operation.getId().getName(service);
                var inputName = operationIndex.expectInputShape(operation).getId().getName(service);
                var outputName = operationIndex.expectOutputShape(operation).getId().getName(service);
                writer.write("function C:$L(input: types.$L, options: any): async.Operation<types.$L>",
                        opName, inputName, outputName);
                writer.indent();
                writer.write("return self:invokeOperation(schemas.Service, schemas.$L, input, options) as async.Operation<types.$L>",
                        opSchemaName, outputName);
                writer.dedent();
                writer.write("end");
                writer.write("");
            }

            writer.write("return M");
        });
    }

    private static final java.util.Set<String> TEAL_RESERVED = java.util.Set.of(
        "and", "break", "do", "else", "elseif", "end", "false", "for",
        "function", "goto", "if", "in", "local", "nil", "not", "or",
        "repeat", "return", "then", "true", "until", "while",
        "record", "enum", "type"
    );

    private static void writeNestedRecordFromShape(LuaWriter writer, Shape shape, ServiceShape service, Model model) {
        var name = shape.getId().getName(service);
        writeDoc(writer, shape);
        writer.write("record $L", name);
        writer.indent();
        for (var member : shape.members()) {
            var memberName = member.getMemberName();
            if (TEAL_RESERVED.contains(memberName)) continue;
            var target = model.expectShape(member.getTarget());
            String tealType;
            if (member.hasTrait(HttpPayloadTrait.class) && target.hasTrait(StreamingTrait.class)) {
                tealType = "function(): string, string";
            } else {
                tealType = toTealType(target, service, model);
            }
            writeDoc(writer, member);
            writer.write("$L: $L", memberName, tealType);
        }
        writer.dedent();
        writer.write("end");
    }

    private static void writeNestedRecord(LuaWriter writer, StructureShape shape, ServiceShape service, Model model) {
        var name = shape.getId().getName(service);
        writeDoc(writer, shape);
        writer.write("record $L", name);
        writer.indent();
        for (var member : shape.members()) {
            var memberName = member.getMemberName();
            if (TEAL_RESERVED.contains(memberName)) continue;
            var target = model.expectShape(member.getTarget());
            String tealType;
            if (member.hasTrait(HttpPayloadTrait.class) && target.hasTrait(StreamingTrait.class)) {
                tealType = "function(): string, string";
            } else {
                tealType = toTealType(target, service, model);
            }
            writeDoc(writer, member);
            writer.write("$L: $L", memberName, tealType);
        }
        writer.dedent();
        writer.write("end");
    }

    private static void writeNestedEnum(LuaWriter writer, EnumShape shape, ServiceShape service) {
        var name = shape.getId().getName(service);
        var values = shape.getEnumValues().values();
        writer.write("enum $L", name);
        writer.indent();
        for (var v : values) {
            writer.write("\"$L\"", v);
        }
        writer.dedent();
        writer.write("end");
    }

    private static void writeStructureRecord(LuaWriter writer, StructureShape shape, ServiceShape service, Model model) {
        var name = shape.getId().getName(service);
        writeDoc(writer, shape);
        writer.write("local record $L", name);
        writer.indent();
        for (var member : shape.members()) {
            var memberName = member.getMemberName();
            if (TEAL_RESERVED.contains(memberName)) continue;
            var target = model.expectShape(member.getTarget());
            String tealType;
            if (member.hasTrait(HttpPayloadTrait.class) && target.hasTrait(StreamingTrait.class)) {
                tealType = "function(): string, string";
            } else {
                tealType = toTealType(target, service, model);
            }
            writeDoc(writer, member);
            writer.write("$L: $L", memberName, tealType);
        }
        writer.dedent();
        writer.write("end");
    }

    private static void writeEnumType(LuaWriter writer, EnumShape shape, ServiceShape service) {
        var name = shape.getId().getName(service);
        var values = shape.getEnumValues().values();
        writer.write("local enum $L", name);
        writer.indent();
        for (var v : values) {
            writer.write("\"$L\"", v);
        }
        writer.dedent();
        writer.write("end");
    }

    private static void writeIntEnumType(LuaWriter writer, IntEnumShape shape, ServiceShape service) {
        var name = shape.getId().getName(service);
        writer.write("type $L = number", name);
    }

    private static String toTealType(Shape shape, ServiceShape service, Model model) {
        return switch (shape.getType()) {
            case STRING, ENUM -> "string";
            case BOOLEAN -> "boolean";
            case BYTE, SHORT, INTEGER, LONG, FLOAT, DOUBLE,
                 BIG_INTEGER, BIG_DECIMAL, INT_ENUM -> "number";
            case TIMESTAMP -> "number";
            case BLOB -> "string";
            case LIST -> {
                var member = shape.asListShape().get().getMember();
                var target = model.expectShape(member.getTarget());
                yield "{" + toTealType(target, service, model) + "}";
            }
            case MAP -> {
                var mapShape = shape.asMapShape().get();
                var keyTarget = model.expectShape(mapShape.getKey().getTarget());
                var valueTarget = model.expectShape(mapShape.getValue().getTarget());
                yield "{" + toTealType(keyTarget, service, model) + " : " + toTealType(valueTarget, service, model) + "}";
            }
            case STRUCTURE, UNION -> shape.getId().getName(service);
            case DOCUMENT -> "any";
            default -> "any";
        };
    }

    private static boolean isInService(Shape shape, ServiceShape service, Model model) {
        var topDown = TopDownIndex.of(model);
        // Simple heuristic: check if any operation in the service references this shape
        var operationIndex = OperationIndex.of(model);
        for (var op : topDown.getContainedOperations(service)) {
            var input = operationIndex.expectInputShape(op);
            var output = operationIndex.expectOutputShape(op);
            if (referencesShape(input, shape, model) || referencesShape(output, shape, model)) {
                return true;
            }
        }
        return false;
    }

    private static boolean referencesShape(Shape container, Shape target, Model model) {
        if (container.getId().equals(target.getId())) return true;
        for (var member : container.members()) {
            if (member.getTarget().equals(target.getId())) return true;
        }
        return false;
    }

    private static void writeDoc(LuaWriter writer, Shape shape) {
        shape.getTrait(DocumentationTrait.class).ifPresent(trait -> {
            var text = trait.getValue()
                    .replaceAll("<[^>]+>", "")
                    .replaceAll("&nbsp;", " ")
                    .replaceAll("&amp;", "&")
                    .replaceAll("&lt;", "<")
                    .replaceAll("&gt;", ">")
                    .replaceAll("&quot;", "\"")
                    .replaceAll(" +", " ")
                    .strip();
            if (text.isEmpty()) return;
            for (var line : text.split("\n")) {
                var stripped = line.strip();
                if (!stripped.isEmpty()) {
                    writer.write("-- $L", stripped);
                }
            }
        });
    }
}
