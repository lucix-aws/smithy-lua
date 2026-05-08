package software.amazon.smithy.lua.codegen;

import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import software.amazon.smithy.model.Model;
import software.amazon.smithy.model.node.Node;
import software.amazon.smithy.model.shapes.MemberShape;
import software.amazon.smithy.model.shapes.ServiceShape;
import software.amazon.smithy.model.shapes.Shape;
import software.amazon.smithy.model.shapes.ShapeType;
import software.amazon.smithy.model.shapes.StructureShape;
import software.amazon.smithy.model.traits.ClientOptionalTrait;
import software.amazon.smithy.model.traits.DefaultTrait;
import software.amazon.smithy.model.traits.DocumentationTrait;
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

/**
 * Generates type records (into types.tl) and schemas (into schemas.tl) for
 * structures, errors, and unions.
 */
final class StructureGenerator {

    private static final Set<String> LUA_RESERVED = Set.of(
        "and", "break", "do", "else", "elseif", "end", "false", "for",
        "function", "goto", "if", "in", "local", "nil", "not", "or",
        "repeat", "return", "then", "true", "until", "while"
    );

    private static final Set<String> TEAL_RESERVED = Set.of(
        "and", "break", "do", "else", "elseif", "end", "false", "for",
        "function", "goto", "if", "in", "local", "nil", "not", "or",
        "repeat", "return", "then", "true", "until", "while",
        "record", "enum", "type"
    );

    private final LuaContext context;
    private final Shape shape;
    private final Model model;
    private final ServiceShape service;

    StructureGenerator(LuaContext context, Shape shape) {
        this.context = context;
        this.shape = shape;
        this.model = context.model();
        this.service = context.service();
    }

    // --- Type record (types.tl) ---

    void writeType(LuaWriter writer) {
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
                tealType = toTealType(target);
            }
            writeDoc(writer, member);
            writer.write("$L: $L", memberName, tealType);
        }
        writer.dedent();
        writer.write("end");
        writer.write("");
    }

    // --- Schema (schemas.tl) ---

    void writeSchema(LuaWriter writer) {
        var name = shape.getId().getName(service);

        if (shape.getType() == ShapeType.UNION) {
            writeUnionSchema(writer, name);
        } else {
            writeStructureSchema(writer, name);
        }
    }

    private void writeStructureSchema(LuaWriter writer, String name) {
        // Unit shapes reference the shared prelude instance
        if ("Unit".equals(schemaIdName()) && shape.members().isEmpty()) {
            writer.write("M.$L = prelude.Unit", name);
            return;
        }

        writer.write("M.$L = schema.new({", name);
        writer.indent();
        writer.write("id = id.from(_N, $S),", schemaIdName());
        writer.write("type = \"structure\",");
        writeStructTraits(writer);
        writeMembers(writer);
        writer.dedent();
        writer.write("})");
    }

    private void writeUnionSchema(LuaWriter writer, String name) {
        writer.write("M.$L = schema.new({", name);
        writer.indent();
        writer.write("id = id.from(_N, $S),", schemaIdName());
        writer.write("type = \"union\",");
        writeMembers(writer);
        writer.dedent();
        writer.write("})");
    }

    private void writeMembers(LuaWriter writer) {
        if (!shape.members().isEmpty()) {
            writer.write("members = {");
            writer.indent();
            for (var member : shape.members()) {
                writeMemberSchema(writer, member);
            }
            writer.dedent();
            writer.write("},");
        }
    }

    private void writeStructTraits(LuaWriter writer) {
        var traitEntries = new ArrayList<String>();
        var name = shape.getId().getName(service);
        var rawName = shape.getId().getName();
        var structShape = (StructureShape) shape;

        structShape.getTrait(ErrorTrait.class).ifPresent(t ->
                traitEntries.add("[traits.ERROR] = { value = \"" + t.getValue() + "\" }"));

        structShape.getTrait(XmlNameTrait.class).ifPresent(t ->
                traitEntries.add("[traits.XML_NAME] = { name = \"" + t.getValue() + "\" }"));
        if (traitEntries.stream().noneMatch(s -> s.contains("XML_NAME")) && !rawName.equals(name)) {
            traitEntries.add("[traits.XML_NAME] = { name = \"" + rawName + "\" }");
        }

        structShape.getTrait(XmlNamespaceTrait.class).ifPresent(ns -> {
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

    private void writeMemberSchema(LuaWriter writer, MemberShape member) {
        var target = model.expectShape(member.getTarget());
        var memberName = member.getMemberName();
        var parentName = shape.getId().getName();

        var luaKey = LUA_RESERVED.contains(memberName) ? "[\"" + memberName + "\"]" : memberName;
        writer.write("$L = schema.new({", luaKey);
        writer.indent();
        writer.write("id = id.from(_N, $S, $S),", parentName, memberName);
        writer.write("type = $S,", toLuaSchemaType(target));
        writer.write("name = $S,", memberName);
        writer.write("target_id = $L,", targetIdExpr(target));

        var targetType = target.getType();
        if (targetType == ShapeType.STRUCTURE || targetType == ShapeType.UNION) {
            writer.write("target = M.$L,", target.getId().getName(service));
        }

        if (target.getType() == ShapeType.LIST) {
            writeListMember(writer, target);
        }

        if (target.getType() == ShapeType.MAP) {
            writeMapMembers(writer, target);
        }

        // Effective traits (merged: target + member)
        var effectiveTraits = collectTraits(member);
        var directTraits = collectDirectTraits(member);

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

    private void writeListMember(LuaWriter writer, Shape target) {
        var listMember = target.asListShape().get().getMember();
        var listTarget = model.expectShape(listMember.getTarget());
        var listMemberRef = targetSchemaRef(listTarget);
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
            var innerMember = listTarget.asListShape().get().getMember();
            var innerTarget = model.expectShape(innerMember.getTarget());
            writer.write("list_member = schema.new({ type = \"list\", list_member = $L }),", targetSchemaRef(innerTarget));
        } else if (!listMemberTraits.isEmpty()) {
            writer.write("list_member = schema.new({ type = $S, target = $L, traits = { $L } }),",
                    toLuaSchemaType(listTarget), listMemberRef, String.join(", ", listMemberTraits));
        } else {
            writer.write("list_member = $L,", listMemberRef);
        }
    }

    private void writeMapMembers(LuaWriter writer, Shape target) {
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
            writer.write("map_key = $L,", targetSchemaRef(keyTarget));
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
            var innerMap = valueTarget.asMapShape().get();
            var innerKeyMember = innerMap.getKey();
            var innerValueMember = innerMap.getValue();
            var innerKeyTarget = model.expectShape(innerKeyMember.getTarget());
            var innerValueTarget = model.expectShape(innerValueMember.getTarget());
            var innerKeyRef = targetSchemaRef(innerKeyTarget);
            var innerValueRef = targetSchemaRef(innerValueTarget);
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
            var innerListMember = valueTarget.asListShape().get().getMember();
            var innerListTarget = model.expectShape(innerListMember.getTarget());
            writer.write("map_value = schema.new({ type = \"list\", list_member = $L }),",
                    targetSchemaRef(innerListTarget));
        } else if (!valueTraits.isEmpty()) {
            writer.write("map_value = schema.new({ type = $S, target = $L, traits = { $L } }),",
                    toLuaSchemaType(valueTarget), targetSchemaRef(valueTarget), String.join(", ", valueTraits));
        } else {
            writer.write("map_value = $L,", targetSchemaRef(valueTarget));
        }
    }

    // --- Trait collection ---

    private List<String> collectTraits(MemberShape member) {
        var entries = new ArrayList<String>();
        var target = model.expectShape(member.getTarget());
        addMemberTraitEntries(entries, member);
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

    private List<String> collectDirectTraits(MemberShape member) {
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

    // --- Helpers ---

    private String schemaIdName() {
        return shape.getTrait(OriginalShapeIdTrait.class)
                .map(t -> t.getOriginalId().getName())
                .orElse(shape.getId().getName());
    }

    private String targetIdExpr(Shape target) {
        var targetType = target.getType();
        if (targetType == ShapeType.STRUCTURE || targetType == ShapeType.UNION) {
            return "id.from(_N, \"" + target.getId().getName() + "\")";
        }
        return "prelude." + preludeName(target) + ".id";
    }

    private String targetSchemaRef(Shape target) {
        var targetType = target.getType();
        if (targetType == ShapeType.STRUCTURE || targetType == ShapeType.UNION
                || targetType == ShapeType.LIST || targetType == ShapeType.MAP) {
            return "M." + target.getId().getName(service);
        }
        return "prelude." + preludeName(target);
    }

    private String toTealType(Shape target) {
        return switch (target.getType()) {
            case STRING, ENUM -> "string";
            case BOOLEAN -> "boolean";
            case BYTE, SHORT, INTEGER, LONG, FLOAT, DOUBLE,
                 BIG_INTEGER, BIG_DECIMAL, INT_ENUM, TIMESTAMP -> "number";
            case BLOB -> "string";
            case LIST -> {
                var member = target.asListShape().get().getMember();
                var t = model.expectShape(member.getTarget());
                yield "{" + toTealType(t) + "}";
            }
            case MAP -> {
                var mapShape = target.asMapShape().get();
                var keyTarget = model.expectShape(mapShape.getKey().getTarget());
                var valueTarget = model.expectShape(mapShape.getValue().getTarget());
                yield "{" + toTealType(keyTarget) + " : " + toTealType(valueTarget) + "}";
            }
            case STRUCTURE, UNION -> target.getId().getName(service);
            case DOCUMENT -> "any";
            default -> "any";
        };
    }

    private static String toLuaSchemaType(Shape shape) {
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

    private static String preludeName(Shape target) {
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
