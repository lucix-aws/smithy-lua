package software.amazon.smithy.lua.codegen;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
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
import software.amazon.smithy.model.shapes.UnionShape;
import software.amazon.smithy.model.traits.ClientOptionalTrait;
import software.amazon.smithy.model.traits.DefaultTrait;
import software.amazon.smithy.model.traits.ErrorTrait;
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
import software.amazon.smithy.model.traits.XmlFlattenedTrait;
import software.amazon.smithy.model.traits.XmlNameTrait;
import software.amazon.smithy.model.traits.XmlNamespaceTrait;
import software.amazon.smithy.rulesengine.traits.ContextParamTrait;
import software.amazon.smithy.rulesengine.traits.EndpointRuleSetTrait;

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

        // Generate endpoint_rules.lua from endpointRuleSet trait
        EndpointRulesetGenerator.generate(directive.context());
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

        // Collect config resolvers from all integrations
        List<ConfigResolver> configResolvers = new ArrayList<>();
        for (var integration : context.integrations()) {
            configResolvers.addAll(integration.getConfigResolvers(context));
        }

        context.writerDelegator().useShapeWriter(service, writer -> {
            var topDown = TopDownIndex.of(model);
            var operations = topDown.getContainedOperations(service);
            var operationIndex = OperationIndex.of(model);

            // Require base client
            writer.addRequire("base_client", "client");
            writer.addRequire("defaults", "defaults");

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
            writer.block("function M.new(cfg)", () -> {
                writer.write("cfg = cfg or {}");
                writer.write("cfg.service_id = $S", service.getId().getName());

                // Determine signing name from @aws.auth#sigv4 trait
                String signingName = service.getId().getName().toLowerCase(Locale.US);
                var sigv4Trait = service.getTrait(
                        software.amazon.smithy.aws.traits.auth.SigV4Trait.class);
                if (sigv4Trait.isPresent()) {
                    signingName = sigv4Trait.get().getName();
                }

                // Service-specific: protocol resolver
                writeProtocolResolver(writer, service);

                // Service-specific: endpoint resolver
                if (service.hasTrait(EndpointRuleSetTrait.class)) {
                    writer.addRequire("endpoint_rules", serviceNs + ".endpoint_rules");
                    writer.addRequire("endpoint", "endpoint");
                    writer.block("if not cfg.endpoint_provider then", () -> {
                        writer.block("cfg.endpoint_provider = function(params)", () -> {
                            writer.write("return endpoint.resolve(endpoint_rules, params)");
                        });
                    });
                }

                // Default auth scheme resolver: maps effective_auth_schemes to options
                // with signer properties (signing_name from model, region from config)
                final String finalSigningName = signingName;
                writer.block("if not cfg.auth_scheme_resolver then", () -> {
                    writer.block("cfg.auth_scheme_resolver = function(operation)", () -> {
                        writer.write("local options = {}");
                        writer.block("for _, scheme_id in ipairs(operation.effective_auth_schemes) do", () -> {
                            writer.write("if scheme_id == \"aws.auth#sigv4\" or scheme_id == \"aws.auth#sigv4a\" then");
                            writer.indent();
                            writer.write("options[#options + 1] = { scheme_id = scheme_id, signer_properties = { signing_name = $S, signing_region = cfg.region } }",
                                    finalSigningName);
                            writer.dedent();
                            writer.write("else");
                            writer.indent();
                            writer.write("options[#options + 1] = { scheme_id = scheme_id }");
                            writer.dedent();
                            writer.write("end");
                        });
                        writer.write("return options");
                    });
                });

                // Generic defaults from smithy-lua runtime
                writer.write("defaults.resolve_auth_schemes(cfg)");
                writer.write("defaults.resolve_identity_resolvers(cfg)");
                writer.write("defaults.resolve_http_client(cfg)");
                writer.write("defaults.resolve_retry_strategy(cfg)");

                // Integration-provided resolvers (e.g. identity_resolver from aws-sdk-lua)
                for (var resolver : configResolvers) {
                    writer.addRequire(resolver.requireAlias(), resolver.requirePath());
                    writer.write(resolver.functionCall());
                }

                writer.write("local self = setmetatable(base_client.new(cfg), Client)");
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

    private void writeProtocolResolver(LuaWriter writer, ServiceShape service) {
        // Detect protocol from service traits
        var traits = service.getAllTraits();
        String protocolRequire = null;
        String protocolExpr = null;

        for (var traitId : traits.keySet()) {
            var name = traitId.toString();
            if (name.equals("aws.protocols#awsJson1_0")) {
                protocolRequire = "protocol.awsjson";
                protocolExpr = "awsjson_protocol.new(\"1.0\")";
            } else if (name.equals("aws.protocols#awsJson1_1")) {
                protocolRequire = "protocol.awsjson";
                protocolExpr = "awsjson_protocol.new(\"1.1\")";
            } else if (name.equals("aws.protocols#restJson1")) {
                protocolRequire = "protocol.restjson";
                protocolExpr = "restjson_protocol.new()";
            } else if (name.equals("aws.protocols#restXml")) {
                protocolRequire = "protocol.restxml";
                protocolExpr = "restxml_protocol.new()";
            } else if (name.equals("aws.protocols#awsQuery")) {
                protocolRequire = "protocol.query";
                protocolExpr = "query_protocol.new(\"awsQuery\")";
            } else if (name.equals("aws.protocols#ec2Query")) {
                protocolRequire = "protocol.query";
                protocolExpr = "query_protocol.new(\"ec2Query\")";
            } else if (name.equals("smithy.protocols#rpcv2Cbor")) {
                protocolRequire = "protocol.rpcv2cbor";
                protocolExpr = "rpcv2cbor_protocol.new()";
            }
        }

        if (protocolRequire != null) {
            var alias = protocolRequire.replace("protocol.", "") + "_protocol";
            writer.addRequire(alias, protocolRequire);
            final var expr = protocolExpr;
            writer.block("if not cfg.protocol then", () -> {
                writer.write("cfg.protocol = " + expr);
            });
        }
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

        // Get input/output shapes
        var inputShape = operationIndex.expectInputShape(operation);
        var outputShape = operationIndex.expectOutputShape(operation);

        // Check for input event streams (duplex or input-only) — skip these operations
        for (var member : inputShape.members()) {
            var target = model.expectShape(member.getTarget());
            if (target.hasTrait(StreamingTrait.class) && target.isUnionShape()) {
                // Input event stream: not supported, skip this operation
                return;
            }
        }

        // Check for output event stream
        String outputEventStreamUnion = null;
        for (var member : outputShape.members()) {
            var target = model.expectShape(member.getTarget());
            if (target.hasTrait(StreamingTrait.class) && target.isUnionShape()) {
                outputEventStreamUnion = target.getId().getName(service);
                break;
            }
        }
        final String eventStreamUnion = outputEventStreamUnion;

        // Get HTTP trait if present
        var httpTrait = operation.getTrait(HttpTrait.class).orElse(null);
        String httpMethod = httpTrait != null ? httpTrait.getMethod() : "POST";
        String httpPath = httpTrait != null ? httpTrait.getUri().toString() : "/";

        var inputName = inputShape.getId().getName(service);
        var outputName = outputShape.getId().getName(service);

        // Add require for types module
        var serviceNs = LuaSymbolProvider.getServiceNamespace(service);
        writer.addRequire("types", serviceNs + ".types");

        // Compute effective auth schemes for this operation
        var serviceIndex = ServiceIndex.of(model);
        var effectiveAuth = serviceIndex.getEffectiveAuthSchemes(service, operation);

        writer.block("function Client:" + opSymbol.getName() + "(input, options)", () -> {
            writer.write("return self:invokeOperation(input, {");
            writer.indent();
            writer.write("name = $S,", opName);
            writer.write("input_schema = types.$L,", inputName);
            writer.write("output_schema = types.$L,", outputName);
            writer.write("http_method = $S,", httpMethod);
            writer.write("http_path = $S,", httpPath);

            // Event stream: reference the streaming union schema
            if (eventStreamUnion != null) {
                writer.write("event_stream = types.$L,", eventStreamUnion);
            }

            // Emit effective auth scheme IDs (static from model)
            writer.write("effective_auth_schemes = {");
            writer.indent();
            for (var schemeId : effectiveAuth.keySet()) {
                writer.write("$S,", schemeId.toString());
            }
            writer.dedent();
            writer.write("},");

            // Emit context_params from @contextParam traits on input members
            var contextParams = new TreeMap<String, String>();
            for (var member : inputShape.members()) {
                member.getTrait(ContextParamTrait.class).ifPresent(t ->
                        contextParams.put(t.getName(), member.getMemberName()));
            }
            if (!contextParams.isEmpty()) {
                writer.write("context_params = {");
                writer.indent();
                for (var entry : contextParams.entrySet()) {
                    writer.write("$L = $S,", entry.getKey(), entry.getValue());
                }
                writer.dedent();
                writer.write("},");
            }

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
            writer.write("id = $S,", name);
            if (!shape.members().isEmpty()) {
                writer.write("members = {");
                writer.indent();
                for (var member : shape.members()) {
                    writeMemberSchema(writer, member, model, context.service());
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
        var context = directive.context();
        var serviceNs = LuaSymbolProvider.getServiceNamespace(context.service());
        var typesFile = serviceNs + "/types.lua";
        var enumValues = directive.shape().asEnumShape()
                .map(e -> e.getEnumValues())
                .orElseGet(() -> {
                    // Fallback for old-style @enum on string shapes
                    var map = new java.util.LinkedHashMap<String, String>();
                    directive.shape().asStringShape().ifPresent(s ->
                            s.getTrait(software.amazon.smithy.model.traits.EnumTrait.class).ifPresent(t ->
                                    t.getValues().forEach(v -> {
                                        var name = v.getName().orElse(v.getValue());
                                        map.put(name, v.getValue());
                                    })));
                    return map;
                });
        context.writerDelegator().useFileWriter(typesFile, serviceNs, writer -> {
            var name = directive.shape().getId().getName(context.service());
            writer.write("M.$L = {", name);
            writer.indent();
            for (var entry : enumValues.entrySet()) {
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
        var rawName = shape.getId().getName();
        var model = context.model();

        writer.write("M.$L = {", name);
        writer.indent();
        writer.write("type = $S,", schemaType);
        writer.write("id = $S,", name);

        // Error trait
        shape.getTrait(ErrorTrait.class).ifPresent(t ->
                writer.write("error = $S,", t.getValue()));

        // XML traits on the structure itself
        var structTraits = new TreeMap<String, String>();
        shape.getTrait(XmlNameTrait.class).ifPresent(t ->
                structTraits.put("xml_name", "\"" + t.getValue() + "\""));
        if (!structTraits.containsKey("xml_name") && !rawName.equals(name)) {
            structTraits.put("xml_name", "\"" + rawName + "\"");
        }
        shape.getTrait(XmlNamespaceTrait.class).ifPresent(ns -> {
            var prefix = ns.getPrefix().orElse(null);
            if (prefix != null) {
                structTraits.put("xml_namespace", "{ uri = \"" + ns.getUri() + "\", prefix = \"" + prefix + "\" }");
            } else {
                structTraits.put("xml_namespace", "\"" + ns.getUri() + "\"");
            }
        });
        if (!structTraits.isEmpty()) {
            writer.write("traits = {");
            writer.indent();
            for (var entry : structTraits.entrySet()) {
                writer.write("$L = $L,", entry.getKey(), entry.getValue());
            }
            writer.dedent();
            writer.write("},");
        }

        if (!shape.members().isEmpty()) {
            writer.write("members = {");
            writer.indent();
            for (var member : shape.members()) {
                writeMemberSchema(writer, member, model, context.service());
            }
            writer.dedent();
            writer.write("},");
        }

        writer.dedent();
        writer.write("}");
    }

    private void writeMemberSchema(LuaWriter writer, MemberShape member, software.amazon.smithy.model.Model model,
                                   ServiceShape service) {
        var target = model.expectShape(member.getTarget());
        var targetType = target.getType();

        // For structure/union targets, reference the top-level schema directly
        if (targetType == ShapeType.STRUCTURE || targetType == ShapeType.UNION) {
            var targetName = target.getId().getName(service);
            // Write traits wrapper if needed, otherwise just reference
            var traits = collectTraits(member, model);
            if (traits.isEmpty()) {
                writer.write("$L = M.$L,", member.getMemberName(), targetName);
            } else {
                // Need to merge: create a table that references the schema but adds traits
                // We'll use a pattern: copy type+members from target, add traits
                writer.write("$L = setmetatable({ traits = {", member.getMemberName());
                writer.indent();
                for (var entry : traits.entrySet()) {
                    writer.write("$L = $L,", entry.getKey(), entry.getValue());
                }
                writer.dedent();
                writer.write("} }, { __index = M.$L }),", targetName);
            }
            return;
        }

        writer.write("$L = {", member.getMemberName());
        writer.indent();
        writer.write("type = $S,", toLuaSchemaType(target));

        // If the target is a list, include the member schema
        if (targetType == ShapeType.LIST) {
            var listMember = target.asListShape().get().getMember();
            var listTarget = model.expectShape(listMember.getTarget());
            var listTargetType = listTarget.getType();
            if (listTargetType == ShapeType.STRUCTURE || listTargetType == ShapeType.UNION) {
                writer.write("member = M.$L,", listTarget.getId().getName(service));
            } else {
                writer.write("member = { type = $S },", toLuaSchemaType(listTarget));
            }
        }

        // If the target is a map, include key/value schemas
        if (targetType == ShapeType.MAP) {
            var mapShape = target.asMapShape().get();
            var keyMember = mapShape.getKey();
            var keyTarget = model.expectShape(keyMember.getTarget());
            var valueMember = mapShape.getValue();
            var valueTarget = model.expectShape(valueMember.getTarget());
            var valueTargetType = valueTarget.getType();
            writeMapSubSchema(writer, "key", keyMember, keyTarget, service, model);
            if (valueTargetType == ShapeType.STRUCTURE || valueTargetType == ShapeType.UNION) {
                writer.write("value = M.$L,", valueTarget.getId().getName(service));
            } else {
                writeMapSubSchema(writer, "value", valueMember, valueTarget, service, model);
            }
        }

        // Collect traits relevant to serde
        var traits = collectTraits(member, model);

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

    private void writeMapSubSchema(LuaWriter writer, String field, MemberShape member, Shape target,
                                    ServiceShape service, software.amazon.smithy.model.Model model) {
        var subTraits = new TreeMap<String, String>();
        member.getTrait(XmlNameTrait.class).ifPresent(t ->
                subTraits.put("xml_name", "\"" + t.getValue() + "\""));
        member.getTrait(XmlNamespaceTrait.class).ifPresent(ns -> {
            var prefix = ns.getPrefix().orElse(null);
            if (prefix != null) {
                subTraits.put("xml_namespace", "{ uri = \"" + ns.getUri() + "\", prefix = \"" + prefix + "\" }");
            } else {
                subTraits.put("xml_namespace", "\"" + ns.getUri() + "\"");
            }
        });
        if (subTraits.isEmpty()) {
            writer.write("$L = { type = $S },", field, toLuaSchemaType(target));
        } else {
            writer.write("$L = { type = $S, traits = {", field, toLuaSchemaType(target));
            writer.indent();
            for (var entry : subTraits.entrySet()) {
                writer.write("$L = $L,", entry.getKey(), entry.getValue());
            }
            writer.dedent();
            writer.write("} },");
        }
    }

    private TreeMap<String, String> collectTraits(MemberShape member) {
        return collectTraits(member, null);
    }

    private TreeMap<String, String> collectTraits(MemberShape member, software.amazon.smithy.model.Model model) {
        var traits = new TreeMap<String, String>();
        if (member.hasTrait(RequiredTrait.class)) traits.put("required", "true");
        if (!member.hasTrait(ClientOptionalTrait.class)) {
            member.getTrait(DefaultTrait.class).ifPresent(t -> {
                var node = t.toNode();
                traits.put("default", nodeToLua(node));
            });
        }
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
        if (member.hasTrait(XmlFlattenedTrait.class)) traits.put("xml_flattened", "true");
        member.getTrait(XmlNamespaceTrait.class).ifPresent(ns -> {
            var prefix = ns.getPrefix().orElse(null);
            if (prefix != null) {
                traits.put("xml_namespace", "{ uri = \"" + ns.getUri() + "\", prefix = \"" + prefix + "\" }");
            } else {
                traits.put("xml_namespace", "\"" + ns.getUri() + "\"");
            }
        });
        // @timestampFormat: check member first, then target shape
        member.getTrait(TimestampFormatTrait.class).ifPresent(t ->
                traits.put("timestamp_format", "\"" + t.getValue() + "\""));
        if (member.hasTrait(IdempotencyTokenTrait.class)) traits.put("idempotency_token", "true");
        if (member.hasTrait(EventHeaderTrait.class)) traits.put("event_header", "true");
        if (member.hasTrait(EventPayloadTrait.class)) traits.put("event_payload", "true");
        // Check target shape for traits that can be on the target
        if (model != null) {
            var target = model.expectShape(member.getTarget());
            // @timestampFormat on target (if not already on member)
            if (!traits.containsKey("timestamp_format")) {
                target.getTrait(TimestampFormatTrait.class).ifPresent(t ->
                        traits.put("timestamp_format", "\"" + t.getValue() + "\""));
            }
            target.getTrait(MediaTypeTrait.class).ifPresent(t ->
                    traits.put("media_type", "\"" + t.getValue() + "\""));
        }
        return traits;
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
