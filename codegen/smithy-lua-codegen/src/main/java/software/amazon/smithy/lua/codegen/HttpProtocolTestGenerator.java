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
import software.amazon.smithy.model.shapes.StructureShape;
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
        "SDKAppendsGzipAndIgnoresHttpProvidedEncoding_ec2Query"
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
                        serviceNs + "/test_" + toSnake(opName) + "_request.lua", serviceNs, writer ->
                        writeRequestTests(writer, serviceNs, service, opName, inputShape, cases, protocol));
            });

            operation.getTrait(HttpResponseTestsTrait.class).ifPresent(trait -> {
                var cases = filterCases(trait.getTestCases(), protocol);
                if (cases.isEmpty()) return;
                var outputShape = operationIndex.expectOutputShape(operation);
                context.writerDelegator().useFileWriter(
                        serviceNs + "/test_" + toSnake(opName) + "_response.lua", serviceNs, writer ->
                        writeResponseTests(writer, serviceNs, service, opName, outputShape, cases, protocol));
            });

            for (var errorId : operation.getErrors(service)) {
                var errorShape = model.expectShape(errorId, StructureShape.class);
                errorShape.getTrait(HttpResponseTestsTrait.class).ifPresent(trait -> {
                    var cases = filterCases(trait.getTestCases(), protocol);
                    if (cases.isEmpty()) return;
                    var errorName = errorShape.getId().getName(service);
                    context.writerDelegator().useFileWriter(
                            serviceNs + "/test_" + toSnake(opName) + "_" + toSnake(errorName) + "_error.lua", serviceNs, writer ->
                            writeErrorTests(writer, serviceNs, service, opName, errorShape, errorName, cases, protocol));
                });
            }
        }
    }

    private void writeRequestTests(LuaWriter w, String ns, ServiceShape svc,
            String opName, StructureShape inputShape, List<HttpRequestTestCase> cases, String proto) {
        writePreamble(w, ns, proto, svc);
        w.write("");
        for (var tc : cases) {
            if (SKIP_TESTS.contains(tc.getId())) {
                w.write("test($S, function() end) -- SKIP: not implemented", tc.getId());
                w.write("");
                continue;
            }
            w.write("test($S, function()", tc.getId());
            w.indent();
            w.write("local input = $L", nodesToLua(tc.getParams()));
            w.write("local operation = {");
            w.indent();
            w.write("name = $S,", opName);
            w.write("input_schema = types.$L,", inputShape.getId().getName(svc));
            w.write("output_schema = {},");
            w.write("http_method = $S,", tc.getMethod());
            w.write("http_path = $S,", tc.getUri());
            w.dedent();
            w.write("}");
            w.write("local request, err = protocol:serialize(input, operation)");
            w.write("assert(not err, \"serialize error: \" .. tostring(err))");
            w.write("assert_eq(request.method, $S, \"method\")", tc.getMethod());
            w.write("assert_eq(request.url, $S, \"url\")", tc.getUri());
            for (var e : tc.getHeaders().entrySet()) {
                w.write("assert_header(request, $S, $S)", e.getKey(), e.getValue());
            }
            for (var h : tc.getForbidHeaders()) {
                w.write("assert_no_header(request, $S)", h);
            }
            tc.getBody().ifPresent(body -> {
                w.write("local body_str = read_body(request.body)");
                if (body.isEmpty()) {
                    w.write("assert(body_str == \"\" or body_str == nil, \"expected empty body, got: \" .. tostring(body_str))");
                } else {
                    var mediaType = tc.getBodyMediaType().orElse("");
                    if (mediaType.contains("json")) {
                        w.write("assert_json_eq(body_str, $L)", luaLongString(body));
                    } else {
                        w.write("assert_eq(body_str, $L, \"body\")", luaLongString(body));
                    }
                }
            });
            w.dedent();
            w.write("end)");
            w.write("");
        }
        writeFooter(w);
    }

    private void writeResponseTests(LuaWriter w, String ns, ServiceShape svc,
            String opName, StructureShape outputShape, List<HttpResponseTestCase> cases, String proto) {
        writePreamble(w, ns, proto, svc);
        w.write("");
        for (var tc : cases) {
            if (SKIP_TESTS.contains(tc.getId())) {
                w.write("test($S, function() end) -- SKIP: not implemented", tc.getId());
                w.write("");
                continue;
            }
            w.write("test($S, function()", tc.getId());
            w.indent();
            writeMockResponse(w, tc);
            w.write("local operation = {");
            w.indent();
            w.write("name = $S,", opName);
            w.write("input_schema = {},");
            w.write("output_schema = types.$L,", outputShape.getId().getName(svc));
            w.write("http_method = \"POST\",");
            w.write("http_path = \"/\",");
            w.dedent();
            w.write("}");
            w.write("local output, err = protocol:deserialize(response, operation)");
            w.write("assert(not err, \"deserialize error: \" .. tostring(err and err.message or err))");
            writeParamAssertions(w, "output", tc.getParams());
            w.dedent();
            w.write("end)");
            w.write("");
        }
        writeFooter(w);
    }

    private void writeErrorTests(LuaWriter w, String ns, ServiceShape svc,
            String opName, StructureShape errorShape, String errorName,
            List<HttpResponseTestCase> cases, String proto) {
        writePreamble(w, ns, proto, svc);
        w.write("");
        for (var tc : cases) {
            if (SKIP_TESTS.contains(tc.getId())) {
                w.write("test($S, function() end) -- SKIP: not implemented", tc.getId());
                w.write("");
                continue;
            }
            w.write("test($S, function()", tc.getId());
            w.indent();
            writeMockResponse(w, tc);
            w.write("local operation = {");
            w.indent();
            w.write("name = $S,", opName);
            w.write("input_schema = {},");
            w.write("output_schema = types.$L,", errorShape.getId().getName(svc));
            w.write("http_method = \"POST\",");
            w.write("http_path = \"/\",");
            w.dedent();
            w.write("}");
            w.write("local output, err = protocol:deserialize(response, operation)");
            w.write("assert(output == nil, \"expected nil output for error response\")");
            w.write("assert(err ~= nil, \"expected error\")");
            w.write("assert_eq(err.type, \"api\", \"error type\")");
            w.write("assert(err.code == $S or (err.code and err.code:find($S, 1, true)),",
                    errorName, errorName);
            w.write("    \"error code: expected $L, got: \" .. tostring(err.code))", errorName);
            writeErrorParamAssertions(w, "err", tc.getParams());
            w.dedent();
            w.write("end)");
            w.write("");
        }
        writeFooter(w);
    }

    // --- Preamble with test helpers (no block() for if/else) ---

    private void writePreamble(LuaWriter w, String ns, String proto, ServiceShape svc) {
        w.write("-- Generated protocol test file — do not edit");
        w.write("-- Protocol: $L", proto);
        w.write("");
        w.write("package.path = \"runtime/?.lua;runtime/?/init.lua;\" .. package.path");
        w.write("");
        w.write("local types = require($S)", ns + ".types");
        w.write("local http = require(\"http\")");
        w.write("local json_decoder = require(\"json.decoder\")");

        var serviceName = svc.getId().getName();
        if (proto.contains("awsJson1_0") || proto.contains("awsJson1_1")) {
            w.write("local protocol_mod = require(\"protocol.awsjson\")");
            w.write("local protocol = protocol_mod.new({ version = $S, service_id = $S })",
                    proto.contains("1_0") ? "1.0" : "1.1", serviceName);
        } else if (proto.contains("restJson")) {
            w.write("local protocol_mod = require(\"protocol.restjson\")");
            w.write("local protocol = protocol_mod.new()");
        } else {
            w.write("-- TODO: protocol module for $L", proto);
            w.write("local protocol = nil");
        }

        w.write("");
        w.write("local pass_count = 0");
        w.write("local skip_count = 0");
        w.write("");

        // test() — write if/else manually to avoid block() end issues
        w.write("local function test(name, fn)");
        w.write("    if not protocol then");
        w.write("        skip_count = skip_count + 1");
        w.write("        print(\"SKIP: \" .. name .. \" (no protocol)\")");
        w.write("        return");
        w.write("    end");
        w.write("    local ok, err = pcall(fn)");
        w.write("    if ok then");
        w.write("        pass_count = pass_count + 1");
        w.write("        print(\"PASS: \" .. name)");
        w.write("    else");
        w.write("        print(\"FAIL: \" .. name .. \"\\n  \" .. tostring(err))");
        w.write("        os.exit(1)");
        w.write("    end");
        w.write("end");
        w.write("");

        // assert_eq
        w.write("local function assert_eq(a, b, msg)");
        w.write("    if a ~= b then");
        w.write("        error((msg or \"assert_eq\") .. \": expected \" .. tostring(b) .. \", got \" .. tostring(a), 2)");
        w.write("    end");
        w.write("end");
        w.write("");

        // assert_header (case-insensitive)
        w.write("local function assert_header(request, key, expected)");
        w.write("    local val = request.headers[key]");
        w.write("    if not val then");
        w.write("        for k, v in pairs(request.headers) do");
        w.write("            if k:lower() == key:lower() then val = v; break end");
        w.write("        end");
        w.write("    end");
        w.write("    assert(val ~= nil, \"missing header: \" .. key)");
        w.write("    assert_eq(val, expected, \"header \" .. key)");
        w.write("end");
        w.write("");

        // assert_no_header
        w.write("local function assert_no_header(request, key)");
        w.write("    for k, _ in pairs(request.headers) do");
        w.write("        if k:lower() == key:lower() then error(\"unexpected header: \" .. key, 2) end");
        w.write("    end");
        w.write("end");
        w.write("");

        // read_body
        w.write("local function read_body(reader)");
        w.write("    if not reader then return \"\" end");
        w.write("    local chunks = {}");
        w.write("    while true do");
        w.write("        local chunk = reader()");
        w.write("        if not chunk then break end");
        w.write("        chunks[#chunks + 1] = chunk");
        w.write("    end");
        w.write("    return table.concat(chunks)");
        w.write("end");
        w.write("");

        // deep_eq
        w.write("local function deep_eq(a, b)");
        w.write("    if type(a) ~= type(b) then return false end");
        w.write("    if type(a) ~= \"table\" then return a == b end");
        w.write("    for k, v in pairs(a) do if not deep_eq(v, b[k]) then return false end end");
        w.write("    for k, _ in pairs(b) do if a[k] == nil then return false end end");
        w.write("    return true");
        w.write("end");
        w.write("");

        // assert_json_eq
        w.write("local function assert_json_eq(actual_str, expected_str)");
        w.write("    local actual = json_decoder.decode(actual_str)");
        w.write("    local expected = json_decoder.decode(expected_str)");
        w.write("    if not deep_eq(actual, expected) then");
        w.write("        error(\"JSON mismatch:\\n  expected: \" .. expected_str .. \"\\n  actual:   \" .. actual_str, 2)");
        w.write("    end");
        w.write("end");
        w.write("");

        // assert_deep_eq
        w.write("local function assert_deep_eq(actual, expected, path)");
        w.write("    path = path or \"\"");
        w.write("    if type(expected) == \"table\" then");
        w.write("        assert(type(actual) == \"table\", path .. \": expected table, got \" .. type(actual))");
        w.write("        for k, v in pairs(expected) do");
        w.write("            assert_deep_eq(actual[k], v, path .. \".\" .. tostring(k))");
        w.write("        end");
        w.write("    else");
        w.write("        if type(expected) == \"number\" and type(actual) == \"number\" and expected ~= expected then");
        w.write("            assert(actual ~= actual, path .. \": expected NaN\")");
        w.write("            return");
        w.write("        end");
        w.write("        assert_eq(actual, expected, path)");
        w.write("    end");
        w.write("end");
    }

    private void writeMockResponse(LuaWriter w, HttpResponseTestCase tc) {
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
        w.write("body = http.string_reader($L),", luaLongString(body));
        w.dedent();
        w.write("}");
    }

    private void writeParamAssertions(LuaWriter w, String var, ObjectNode params) {
        if (params.isEmpty()) return;
        w.write("local expected = $L", nodesToLua(params));
        w.write("assert_deep_eq($L, expected, \"output\")", var);
    }

    private void writeErrorParamAssertions(LuaWriter w, String var, ObjectNode params) {
        if (params.isEmpty()) return;
        for (var e : params.getMembers().entrySet()) {
            var key = e.getKey().getValue();
            if (key.equals("Message") || key.equals("message")) {
                w.write("assert_eq($L.message, $L, \"error message\")", var, nodeToLua(e.getValue()));
            }
        }
    }

    private void writeFooter(LuaWriter w) {
        w.write("print(string.format(\"\\n%d passed, %d skipped\", pass_count, skip_count))");
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

    private String nodeToLua(Node node) {
        if (node instanceof ObjectNode obj) {
            if (obj.isEmpty()) return "{}";
            var sb = new StringBuilder("{\n");
            for (var e : obj.getMembers().entrySet()) {
                sb.append("    ").append(e.getKey().getValue())
                  .append(" = ").append(nodeToLua(e.getValue())).append(",\n");
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
