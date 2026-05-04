package software.amazon.smithy.lua.codegen;

import software.amazon.smithy.model.node.ArrayNode;
import software.amazon.smithy.model.node.Node;
import software.amazon.smithy.model.node.ObjectNode;
import software.amazon.smithy.rulesengine.traits.EndpointRuleSetTrait;

/**
 * Generates an endpoint_rules.lua file containing the service's endpoint
 * ruleset as a Lua table literal.
 */
public final class EndpointRulesetGenerator {

    private EndpointRulesetGenerator() {}

    /**
     * Generate endpoint_rules.lua for the service if it has an endpointRuleSet trait.
     */
    public static void generate(LuaContext context) {
        var service = context.service();
        var trait = service.getTrait(EndpointRuleSetTrait.class).orElse(null);
        if (trait == null) {
            return;
        }

        var serviceNs = LuaSymbolProvider.getServiceNamespace(service);
        var filePath = serviceNs + "/endpoint_rules.lua";

        context.writerDelegator().useFileWriter(filePath, serviceNs, writer -> {
            writer.write("return ");
            writeNode(writer, trait.getRuleSet(), 0);
            writer.write("");
        });
    }

    private static void writeNode(LuaWriter writer, Node node, int depth) {
        switch (node.getType()) {
            case OBJECT -> writeObject(writer, node.expectObjectNode(), depth);
            case ARRAY -> writeArray(writer, node.expectArrayNode(), depth);
            case STRING -> writer.writeInline("$S", node.expectStringNode().getValue());
            case NUMBER -> {
                var num = node.expectNumberNode();
                if (num.isNaturalNumber()) {
                    writer.writeInline("$L", num.getValue().longValue());
                } else {
                    writer.writeInline("$L", num.getValue().doubleValue());
                }
            }
            case BOOLEAN -> writer.writeInline("$L", node.expectBooleanNode().getValue() ? "true" : "false");
            case NULL -> writer.writeInline("nil");
        }
    }

    private static void writeObject(LuaWriter writer, ObjectNode obj, int depth) {
        if (obj.isEmpty()) {
            writer.writeInline("{}");
            return;
        }
        writer.writeInline("{\n");
        var members = obj.getMembers();
        for (var entry : members.entrySet()) {
            var key = entry.getKey().getValue();
            writeIndent(writer, depth + 1);
            // Use bracket notation for keys that aren't valid Lua identifiers
            if (isValidLuaIdentifier(key)) {
                writer.writeInline("$L = ", key);
            } else {
                writer.writeInline("[$S] = ", key);
            }
            writeNode(writer, entry.getValue(), depth + 1);
            writer.writeInline(",\n");
        }
        writeIndent(writer, depth);
        writer.writeInline("}");
    }

    private static void writeArray(LuaWriter writer, ArrayNode arr, int depth) {
        if (arr.isEmpty()) {
            writer.writeInline("{}");
            return;
        }
        writer.writeInline("{\n");
        for (var element : arr) {
            writeIndent(writer, depth + 1);
            writeNode(writer, element, depth + 1);
            writer.writeInline(",\n");
        }
        writeIndent(writer, depth);
        writer.writeInline("}");
    }

    private static void writeIndent(LuaWriter writer, int depth) {
        for (int i = 0; i < depth; i++) {
            writer.writeInline("    ");
        }
    }

    private static boolean isValidLuaIdentifier(String s) {
        if (s.isEmpty()) return false;
        char first = s.charAt(0);
        if (!Character.isLetter(first) && first != '_') return false;
        for (int i = 1; i < s.length(); i++) {
            char c = s.charAt(i);
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
}
