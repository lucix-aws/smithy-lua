package software.amazon.smithy.lua.codegen;

import java.util.List;
import java.util.Set;
import java.util.stream.Collectors;
import java.util.TreeSet;
import software.amazon.smithy.model.knowledge.OperationIndex;
import software.amazon.smithy.model.knowledge.TopDownIndex;
import software.amazon.smithy.model.node.ArrayNode;
import software.amazon.smithy.model.node.BooleanNode;
import software.amazon.smithy.model.node.Node;
import software.amazon.smithy.model.node.NullNode;
import software.amazon.smithy.model.node.NumberNode;
import software.amazon.smithy.model.node.ObjectNode;
import software.amazon.smithy.model.node.StringNode;
import software.amazon.smithy.model.shapes.OperationShape;
import software.amazon.smithy.model.shapes.ServiceShape;
import software.amazon.smithy.model.shapes.ShapeType;
import software.amazon.smithy.model.shapes.StructureShape;
import software.amazon.smithy.model.traits.HttpPayloadTrait;
import software.amazon.smithy.model.traits.HttpTrait;
import software.amazon.smithy.model.traits.StreamingTrait;
import software.amazon.smithy.protocoltests.traits.AppliesTo;
import software.amazon.smithy.protocoltests.traits.HttpMessageTestCase;
import software.amazon.smithy.protocoltests.traits.HttpRequestTestCase;
import software.amazon.smithy.protocoltests.traits.HttpRequestTestsTrait;
import software.amazon.smithy.protocoltests.traits.HttpResponseTestCase;
import software.amazon.smithy.protocoltests.traits.HttpResponseTestsTrait;

/**
 * Generates Lua protocol test files from Smithy @httpRequestTests and
 * @httpResponseTests traits. Wired as a LuaIntegration via SPI.
 */
public final class HttpProtocolTestGenerator implements LuaIntegration {

    // Tests to skip — features not yet implemented
    private static final Set<String> SKIP_TESTS = Set.of(
        // Request compression not implemented
        "SDKAppliedContentEncoding_awsJson1_0",
        "SDKAppliedContentEncoding_awsJson1_1",
        "SDKAppliedContentEncoding_awsQuery",
        "SDKAppliedContentEncoding_ec2Query",
        "SDKAppliedContentEncoding_restJson1",
        "SDKAppliedContentEncoding_restXml",
        "SDKAppendsGzipAndIgnoresHttpProvidedEncoding_awsJson1_0",
        "SDKAppendsGzipAndIgnoresHttpProvidedEncoding_awsJson1_1",
        "SDKAppendsGzipAndIgnoresHttpProvidedEncoding_awsQuery",
        "SDKAppendsGzipAndIgnoresHttpProvidedEncoding_ec2Query",
        "SDKAppendedGzipAfterProvidedEncoding_restJson1",
        "SDKAppendedGzipAfterProvidedEncoding_restXml",
        // Content-MD5 not implemented
        "RestJsonHttpChecksumRequired",
        // Host prefix not implemented (endpoint concern, not protocol)
        "RestJsonHostWithPath",
        "RestJsonHostWithPathNoBasePath",
        // Query-compatible mode header not implemented
        "QueryCompatibleAwsJson10CborSendsQueryModeHeader",
        "QueryCompatibleRpcV2CborSendsQueryModeHeader",
        // Default value population not yet implemented
        "RpcV2CborClientPopulatesDefaultValuesInInput",
        "RpcV2CborClientPopulatesDefaultsValuesWhenMissingInResponse",
        "RpcV2CborClientUsesExplicitlyProvidedMemberValuesOverDefaults"
    );

    @Override
    public void writeAdditionalFiles(LuaContext context) {
        var model = context.model();
        var service = context.service();
        var serviceNs = LuaSymbolProvider.getServiceNamespace(service);
        var topDown = TopDownIndex.of(model);
        var operationIndex = OperationIndex.of(model);

        var protocol = detectProtocol(service);
        if (protocol == null) return;

        for (var operation : new TreeSet<>(topDown.getContainedOperations(service))) {
            var opName = operation.getId().getName(service);

            operation.getTrait(HttpRequestTestsTrait.class).ifPresent(trait -> {
                var cases = filterCases(trait.getTestCases(), protocol);
                if (cases.isEmpty()) return;
                var inputShape = operationIndex.expectInputShape(operation);
                context.writerDelegator().useFileWriter(
                        serviceNs + "/test_" + toSnake(opName) + "_request.tl", serviceNs, writer ->
                        writeRequestTests(writer, serviceNs, service, opName, inputShape, cases, protocol, operation));
            });

            operation.getTrait(HttpResponseTestsTrait.class).ifPresent(trait -> {
                var cases = filterCases(trait.getTestCases(), protocol);
                if (cases.isEmpty()) return;
                var outputShape = operationIndex.expectOutputShape(operation);
                context.writerDelegator().useFileWriter(
                        serviceNs + "/test_" + toSnake(opName) + "_response.tl", serviceNs, writer ->
                        writeResponseTests(writer, serviceNs, service, opName, outputShape, cases, protocol, model));
            });

            for (var errorId : operation.getErrors(service)) {
                var errorShape = model.expectShape(errorId, StructureShape.class);
                errorShape.getTrait(HttpResponseTestsTrait.class).ifPresent(trait -> {
                    var cases = filterCases(trait.getTestCases(), protocol);
                    if (cases.isEmpty()) return;
                    var errorName = errorShape.getId().getName(service);
                    context.writerDelegator().useFileWriter(
                            serviceNs + "/test_" + toSnake(opName) + "_" + toSnake(errorName) + "_error.tl", serviceNs, writer ->
                            writeErrorTests(writer, serviceNs, service, opName, errorShape, errorName, cases, protocol));
                });
            }
        }
    }

    private void writeRequestTests(LuaWriter w, String ns, ServiceShape svc,
            String opName, StructureShape inputShape, List<HttpRequestTestCase> cases, String proto,
            OperationShape operation) {
        writePreamble(w, ns, proto, svc);
        var httpTrait = operation.getTrait(HttpTrait.class).orElse(null);
        var fullUriTemplate = httpTrait != null ? httpTrait.getUri().toString() : null;
        w.write("");
        w.write("describe($S, function()", opName + " request");
        w.indent();
        for (var tc : cases) {
            if (SKIP_TESTS.contains(tc.getId())) {
                w.write("pending($S, function() end)", tc.getId());
                w.write("");
                continue;
            }
            w.write("it($S, function()", tc.getId());
            w.indent();
            w.write("local input = $L", nodesToLua(tc.getParams()));
            w.write("local operation = schema.operation({");
            w.indent();
            w.write("id = shape_id.from($S, $S),", svc.getId().getNamespace(), opName);
            w.write("input = types.$L,", inputShape.getId().getName(svc));
            w.write("output = schema.new({ type = \"structure\" }),");
            w.write("traits = {");
            w.indent();
            w.write("[traits.HTTP] = { method = $S, path = $S },",
                    tc.getMethod(), fullUriTemplate != null ? fullUriTemplate : tc.getUri());
            w.dedent();
            w.write("},");
            w.dedent();
            w.write("})");
            w.write("local request, err = protocol:serialize(input, service, operation)");
            w.write("assert.is_nil(err, \"serialize error: \" .. tostring(err))");
            w.write("assert.are.equal($S, request.method)", tc.getMethod());
            w.write("h.assert_url_path(request.url, $S)", tc.getUri());
            for (var qp : tc.getQueryParams()) {
                w.write("h.assert_query_param(request.url, $S)", qp);
            }
            for (var fqp : tc.getForbidQueryParams()) {
                w.write("h.assert_no_query_param(request.url, $S)", fqp);
            }
            for (var rqp : tc.getRequireQueryParams()) {
                w.write("h.assert_has_query_key(request.url, $S)", rqp);
            }
            for (var e : tc.getHeaders().entrySet()) {
                w.write("h.assert_header(request, $S, $S)", e.getKey(), e.getValue());
            }
            for (var h : tc.getForbidHeaders()) {
                w.write("h.assert_no_header(request, $S)", h);
            }
            tc.getBody().ifPresent(body -> {
                w.write("local body_str = h.read_body(request.body)");
                if (body.isEmpty()) {
                    w.write("assert.is_true(body_str == \"\" or body_str == nil, \"expected empty body\")");
                } else {
                    var mediaType = tc.getBodyMediaType().orElse("");
                    if (mediaType.contains("json")) {
                        w.write("h.assert_json_eq(body_str, $L)", luaLongString(body));
                    } else if (mediaType.contains("xml") || proto.contains("restXml")) {
                        w.write("h.assert_xml_eq(body_str, $L)", luaLongString(body));
                    } else if (mediaType.contains("x-www-form-urlencoded") || proto.contains("Query")) {
                        w.write("h.assert_form_eq(body_str, $L)", luaLongString(body));
                    } else if (mediaType.contains("cbor") || proto.contains("rpcv2Cbor")) {
                        w.write("h.assert_cbor_eq(body_str, h.base64_decode($L))", luaLongString(body));
                    } else {
                        w.write("assert.are.equal($L, body_str)", luaLongString(body));
                    }
                }
            });
            w.dedent();
            w.write("end)");
            w.write("");
        }
        w.dedent();
        w.write("end)");
    }

    private void writeResponseTests(LuaWriter w, String ns, ServiceShape svc,
            String opName, StructureShape outputShape, List<HttpResponseTestCase> cases, String proto,
            software.amazon.smithy.model.Model model) {
        writePreamble(w, ns, proto, svc);
        w.write("");

        String streamingMember = null;
        for (var member : outputShape.members()) {
            if (member.hasTrait(HttpPayloadTrait.class)) {
                var target = model.expectShape(member.getTarget());
                if (target.getType() == ShapeType.BLOB && target.hasTrait(StreamingTrait.class)) {
                    streamingMember = member.getMemberName();
                }
            }
        }

        w.write("describe($S, function()", opName + " response");
        w.indent();
        for (var tc : cases) {
            if (SKIP_TESTS.contains(tc.getId())) {
                w.write("pending($S, function() end)", tc.getId());
                w.write("");
                continue;
            }
            w.write("it($S, function()", tc.getId());
            w.indent();
            writeMockResponse(w, tc, proto);
            w.write("local operation = schema.operation({");
            w.indent();
            w.write("id = shape_id.from($S, $S),", svc.getId().getNamespace(), opName);
            w.write("input = schema.new({ type = \"structure\" }),");
            w.write("output = types.$L,", outputShape.getId().getName(svc));
            w.write("traits = {},");
            w.dedent();
            w.write("})");
            w.write("local output, err = protocol:deserialize(response, operation)");
            w.write("assert.is_nil(err, \"deserialize error: \" .. tostring(err and err.message or err))");
            if (streamingMember != null) {
                w.write("if output.$L then output.$L = h.read_body(output.$L) end",
                        streamingMember, streamingMember, streamingMember);
            }
            writeParamAssertions(w, "output", tc.getParams());
            w.dedent();
            w.write("end)");
            w.write("");
        }
        w.dedent();
        w.write("end)");
    }

    private void writeErrorTests(LuaWriter w, String ns, ServiceShape svc,
            String opName, StructureShape errorShape, String errorName,
            List<HttpResponseTestCase> cases, String proto) {
        writePreamble(w, ns, proto, svc);
        w.write("");
        w.write("describe($S, function()", opName + " " + errorName + " error");
        w.indent();
        for (var tc : cases) {
            if (SKIP_TESTS.contains(tc.getId())) {
                w.write("pending($S, function() end)", tc.getId());
                w.write("");
                continue;
            }
            w.write("it($S, function()", tc.getId());
            w.indent();
            writeMockResponse(w, tc, proto);
            w.write("local operation = schema.operation({");
            w.indent();
            w.write("id = shape_id.from($S, $S),", svc.getId().getNamespace(), opName);
            w.write("input = schema.new({ type = \"structure\" }),");
            w.write("output = types.$L,", errorShape.getId().getName(svc));
            w.write("traits = {},");
            w.dedent();
            w.write("})");
            w.write("local output, err = protocol:deserialize(response, operation)");
            w.write("assert.is_nil(output, \"expected nil output for error response\")");
            w.write("assert.is_not_nil(err, \"expected error\")");
            w.write("assert.are.equal(\"api\", err.type)");
            w.write("assert.is_true(err.code == $S or (err.code and err.code:find($S, 1, true) ~= nil),",
                    errorName, errorName);
            w.write("    \"error code: expected $L, got: \" .. tostring(err.code))", errorName);
            writeErrorParamAssertions(w, "err", tc.getParams());
            w.dedent();
            w.write("end)");
            w.write("");
        }
        w.dedent();
        w.write("end)");
    }

    // --- Preamble with test helpers (no block() for if/else) ---

    private void writePreamble(LuaWriter w, String ns, String proto, ServiceShape svc) {
        w.write("local assert = require(\"luassert\") as any");
        w.write("");
        w.write("-- Generated protocol test file — do not edit");
        w.write("-- Protocol: $L", proto);
        w.write("");
        w.write("local types = require($S)", ns.replace("/", ".") + ".schemas");
        w.write("local schema = require(\"smithy.schema\")");
        w.write("local shape_id = require(\"smithy.shape_id\")");
        w.write("local traits = require(\"smithy.traits\")");
        w.write("local http = require(\"smithy.http\")");
        w.write("local h = require(\"smithy.testing\")");

        var serviceName = svc.getId().getName();
        var serviceNs = svc.getId().getNamespace();
        if (proto.contains("awsJson1_0") || proto.contains("awsJson1_1")) {
            w.write("local protocol_mod = require(\"smithy.protocol.awsjson\")");
            w.write("local protocol = protocol_mod.new({ version = $S })",
                    proto.contains("1_0") ? "1.0" : "1.1");
        } else if (proto.contains("restJson")) {
            w.write("local protocol_mod = require(\"smithy.protocol.restjson\")");
            w.write("local protocol = protocol_mod.new()");
        } else if (proto.contains("restXml")) {
            w.write("local protocol_mod = require(\"smithy.protocol.restxml\")");
            var xmlNs = svc.getTrait(software.amazon.smithy.model.traits.XmlNamespaceTrait.class);
            if (xmlNs.isPresent()) {
                w.write("local protocol = protocol_mod.new({ xml_namespace = { uri = $S } })",
                        xmlNs.get().getUri());
            } else {
                w.write("local protocol = protocol_mod.new()");
            }
        } else if (proto.contains("awsQuery")) {
            w.write("local protocol_mod = require(\"smithy.protocol.awsquery\")");
            w.write("local protocol = protocol_mod.new({ version = $S })", svc.getVersion());
        } else if (proto.contains("ec2Query")) {
            w.write("local protocol_mod = require(\"smithy.protocol.ec2query\")");
            w.write("local protocol = protocol_mod.new({ version = $S })", svc.getVersion());
        } else if (proto.contains("rpcv2Cbor")) {
            w.write("local protocol_mod = require(\"smithy.protocol.rpcv2\")");
            w.write("local protocol = protocol_mod.new_cbor()");
        } else if (proto.contains("rpcv2Json")) {
            w.write("local protocol_mod = require(\"smithy.protocol.rpcv2\")");
            w.write("local protocol = protocol_mod.new_json()");
        } else {
            w.write("-- TODO: protocol module for $L", proto);
            w.write("local protocol = nil");
        }

        w.write("");
        w.write("local service = schema.service({");
        w.write("    id = shape_id.from($S, $S),", serviceNs, serviceName);
        w.write("    version = $S,", svc.getVersion());
        w.write("    traits = {},");
        w.write("})");
    }

    private void writeMockResponse(LuaWriter w, HttpResponseTestCase tc, String proto) {
        w.write("local response = {");
        w.indent();
        w.write("status_code = $L,", tc.getCode());
        w.write("headers = {");
        w.indent();
        for (var e : tc.getHeaders().entrySet()) {
            w.write("[$S] = $S,", e.getKey(), e.getValue());
        }
        w.dedent();
        w.write("},");
        var body = tc.getBody().orElse("");
        if (proto.contains("rpcv2Cbor") && !body.isEmpty()) {
            w.write("body = http.string_reader(h.base64_decode($L)),", luaLongString(body));
        } else {
            w.write("body = http.string_reader($L),", luaLongString(body));
        }
        w.dedent();
        w.write("}");
    }

    private void writeParamAssertions(LuaWriter w, String var, ObjectNode params) {
        if (params.isEmpty()) return;
        w.write("local expected = $L", nodesToLua(params));
        w.write("h.assert_deep_eq($L, expected, \"output\")", var);
    }

    private void writeErrorParamAssertions(LuaWriter w, String var, ObjectNode params) {
        if (params.isEmpty()) return;
        for (var e : params.getMembers().entrySet()) {
            var key = e.getKey().getValue();
            if (key.equals("Message") || key.equals("message")) {
                w.write("assert.are.equal($L, $L.message)", nodeToLua(e.getValue()), var);
            }
        }
    }

    // --- Protocol detection ---

    private String detectProtocol(ServiceShape service) {
        for (var trait : service.getAllTraits().keySet()) {
            var name = trait.toString();
            if (name.contains("awsJson1_0")) return "awsJson1_0";
            if (name.contains("awsJson1_1")) return "awsJson1_1";
            if (name.contains("restJson1")) return "restJson1";
            if (name.contains("restXml")) return "restXml";
            if (name.contains("awsQuery")) return "awsQuery";
            if (name.contains("ec2Query")) return "ec2Query";
            if (name.contains("rpcv2Cbor")) return "rpcv2Cbor";
        }
        return null;
    }

    private <T extends HttpMessageTestCase> List<T> filterCases(List<T> cases, String protocol) {
        return cases.stream()
                .filter(tc -> {
                    var tcProto = tc.getProtocol().getName();
                    if (!tcProto.equals(protocol) && !protocol.contains(tcProto)) return false;
                    return tc.getAppliesTo().map(a -> !a.equals(AppliesTo.SERVER)).orElse(true);
                })
                .collect(Collectors.toList());
    }

    // --- Node to Lua literal ---

    private String nodesToLua(ObjectNode node) {
        if (node == null || node.isEmpty()) return "{}";
        return nodeToLua(node);
    }

    private static boolean isLuaIdentifier(String s) {
        if (s.isEmpty()) return false;
        char c = s.charAt(0);
        if (!Character.isLetter(c) && c != '_') return false;
        for (int i = 1; i < s.length(); i++) {
            c = s.charAt(i);
            if (!Character.isLetterOrDigit(c) && c != '_') return false;
        }
        return true;
    }

    private String nodeToLua(Node node) {
        if (node instanceof ObjectNode obj) {
            if (obj.isEmpty()) return "{}";
            var sb = new StringBuilder("{\n");
            for (var e : obj.getMembers().entrySet()) {
                var key = e.getKey().getValue();
                if (isLuaIdentifier(key)) {
                    sb.append("    ").append(key);
                } else {
                    sb.append("    [\"").append(escLuaStr(key)).append("\"]");
                }
                sb.append(" = ").append(nodeToLua(e.getValue())).append(",\n");
            }
            sb.append("}");
            return sb.toString();
        } else if (node instanceof ArrayNode arr) {
            if (arr.isEmpty()) return "{}";
            var sb = new StringBuilder("{\n");
            for (var elem : arr.getElements()) {
                sb.append("    ").append(nodeToLua(elem)).append(",\n");
            }
            sb.append("}");
            return sb.toString();
        } else if (node instanceof StringNode str) {
            var val = str.getValue();
            if (val.equals("NaN")) return "0/0";
            if (val.equals("Infinity")) return "math.huge";
            if (val.equals("-Infinity")) return "-math.huge";
            return "\"" + escLuaStr(val) + "\"";
        } else if (node instanceof NumberNode num) {
            return num.getValue().toString();
        } else if (node instanceof BooleanNode bool) {
            return bool.getValue() ? "true" : "false";
        } else if (node instanceof NullNode) {
            return "nil";
        }
        return "nil";
    }

    // --- String helpers ---

    /** Lua long string [[...]] — no escaping needed, handles newlines naturally. */
    private static String luaLongString(String s) {
        // Find a long string delimiter level that doesn't conflict with content
        int level = 0;
        while (s.contains("]" + "=".repeat(level) + "]")) level++;
        var eq = "=".repeat(level);
        return "[" + eq + "[" + s + "]" + eq + "]";
    }

    private static String toSnake(String camel) {
        return camel.replaceAll("([a-z])([A-Z])", "$1_$2").toLowerCase();
    }

    private static String escLuaStr(String s) {
        return s.replace("\\", "\\\\").replace("\"", "\\\"")
                .replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t");
    }
}
