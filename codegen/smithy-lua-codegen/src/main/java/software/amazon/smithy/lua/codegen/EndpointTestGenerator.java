package software.amazon.smithy.lua.codegen;

import java.util.List;
import java.util.Map;
import software.amazon.smithy.model.node.ArrayNode;
import software.amazon.smithy.model.node.BooleanNode;
import software.amazon.smithy.model.node.Node;
import software.amazon.smithy.model.node.NullNode;
import software.amazon.smithy.model.node.NumberNode;
import software.amazon.smithy.model.node.ObjectNode;
import software.amazon.smithy.model.node.StringNode;
import software.amazon.smithy.rulesengine.traits.EndpointTestCase;
import software.amazon.smithy.rulesengine.traits.EndpointTestsTrait;
import software.amazon.smithy.rulesengine.traits.ExpectedEndpoint;

/**
 * Generates Lua endpoint ruleset test files from the {@code @endpointTests}
 * trait. Each test case calls {@code endpoint.resolve(ruleset, params)} and
 * asserts the expected URL/headers/properties or error message.
 */
public final class EndpointTestGenerator implements LuaIntegration {

    @Override
    public void writeAdditionalFiles(LuaContext context) {
        var service = context.service();
        var trait = service.getTrait(EndpointTestsTrait.class).orElse(null);
        if (trait == null || trait.getTestCases().isEmpty()) {
            return;
        }

        var serviceNs = LuaSymbolProvider.getServiceNamespace(service);
        var filePath = serviceNs + "/test_endpoint_rules.lua";
        var cases = trait.getTestCases();

        context.writerDelegator().useFileWriter(filePath, serviceNs, writer -> {
            writePreamble(writer, serviceNs);
            writer.write("describe(\"endpoint rules\", function()");
            writer.indent();
            for (int i = 0; i < cases.size(); i++) {
                writeTestCase(writer, cases.get(i), i + 1);
            }
            writer.dedent();
            writer.write("end)");
        });
    }

    private void writePreamble(LuaWriter w, String ns) {
        w.write("-- Generated endpoint ruleset tests — do not edit");
        w.write("");
        w.write("local endpoint = require(\"smithy.endpoint\")");
        w.write("local ruleset = require($S)", ns + ".endpoint_rules");
        w.write("");
    }

    private void writeTestCase(LuaWriter w, EndpointTestCase tc, int index) {
        var doc = tc.getDocumentation().orElse("test case " + index);
        w.write("it($S, function()", doc);
        w.indent();

        w.write("local params = $L", nodeToLua(tc.getParams()));
        w.write("local result, err = endpoint.resolve(ruleset, params)");

        var expect = tc.getExpect();
        if (expect.getError().isPresent()) {
            var expectedErr = expect.getError().get();
            w.write("assert.is_nil(result, \"expected error but got result\")");
            w.write("assert.is_not_nil(err, \"expected error but got nil\")");
            w.write("assert.are.equal($S, err)", expectedErr);
        } else if (expect.getEndpoint().isPresent()) {
            var ep = expect.getEndpoint().get();
            w.write("assert.is_not_nil(result, \"expected endpoint but got error: \" .. tostring(err))");
            w.write("assert.are.equal($S, result.url)", ep.getUrl());

            for (var entry : ep.getHeaders().entrySet()) {
                var headerName = entry.getKey();
                var headerValues = entry.getValue();
                for (int i = 0; i < headerValues.size(); i++) {
                    w.write("assert.is_not_nil(result.headers and result.headers[$S], \"missing header: $L\")",
                            headerName, headerName);
                    w.write("assert.are.equal($S, result.headers[$S][$L])",
                            headerValues.get(i), headerName, i + 1);
                }
            }

            if (!ep.getProperties().isEmpty()) {
                w.write("assert.is_not_nil(result.properties, \"missing properties\")");
                w.write("local expected_props = $L", nodeToLua(objectNodeFromProperties(ep.getProperties())));
                w.write("local function deep_eq(a, b)");
                w.write("    if type(a) ~= type(b) then return false end");
                w.write("    if type(a) ~= \"table\" then return a == b end");
                w.write("    for k, v in pairs(a) do if not deep_eq(v, b[k]) then return false end end");
                w.write("    for k, _ in pairs(b) do if a[k] == nil then return false end end");
                w.write("    return true");
                w.write("end");
                w.write("assert.is_true(deep_eq(result.properties, expected_props), \"properties mismatch\")");
            }
        }

        w.dedent();
        w.write("end)");
        w.write("");
    }

    /** Convert the properties map back to an ObjectNode for nodeToLua. */
    private ObjectNode objectNodeFromProperties(Map<String, Node> properties) {
        var builder = ObjectNode.builder();
        for (var entry : properties.entrySet()) {
            builder.withMember(entry.getKey(), entry.getValue());
        }
        return builder.build();
    }

    private String nodeToLua(Node node) {
        if (node instanceof ObjectNode obj) {
            if (obj.isEmpty()) return "{}";
            var sb = new StringBuilder("{\n");
            for (var e : obj.getMembers().entrySet()) {
                var key = e.getKey().getValue();
                sb.append("    ");
                if (isLuaIdentifier(key)) {
                    sb.append(key);
                } else {
                    sb.append("[\"").append(escLuaStr(key)).append("\"]");
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
            return "\"" + escLuaStr(str.getValue()) + "\"";
        } else if (node instanceof NumberNode num) {
            if (num.isNaturalNumber()) {
                return String.valueOf(num.getValue().longValue());
            }
            return num.getValue().toString();
        } else if (node instanceof BooleanNode bool) {
            return bool.getValue() ? "true" : "false";
        } else if (node instanceof NullNode) {
            return "nil";
        }
        return "nil";
    }

    private static boolean isLuaIdentifier(String s) {
        if (s.isEmpty()) return false;
        char c = s.charAt(0);
        if (!Character.isLetter(c) && c != '_') return false;
        for (int i = 1; i < s.length(); i++) {
            c = s.charAt(i);
            if (!Character.isLetterOrDigit(c) && c != '_') return false;
        }
        return !isLuaKeyword(s);
    }

    private static boolean isLuaKeyword(String s) {
        return switch (s) {
            case "and", "break", "do", "else", "elseif", "end", "false", "for",
                 "function", "goto", "if", "in", "local", "nil", "not", "or",
                 "repeat", "return", "then", "true", "until", "while" -> true;
            default -> false;
        };
    }

    private static String escLuaStr(String s) {
        return s.replace("\\", "\\\\").replace("\"", "\\\"")
                .replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t");
    }
}
