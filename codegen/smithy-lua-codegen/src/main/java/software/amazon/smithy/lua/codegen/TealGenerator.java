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
        generateClientDecl(delegator, model, service, serviceNs, symbolProvider);
    }

    private static void generateTypesDecl(
            WriterDelegator<LuaWriter> delegator,
            Model model,
            ServiceShape service,
            String serviceNs,
            SymbolProvider symbolProvider
    ) {
        var file = serviceNs + "/types.d.tl";
        delegator.useFileWriter(file, serviceNs, writer -> {
            var topDown = TopDownIndex.of(model);
            var operationIndex = OperationIndex.of(model);

            // Collect all shapes that go into types.lua
            var shapes = model.getShapesWithTrait(software.amazon.smithy.model.traits.TraitDefinition.class);

            // Generate records for all structures, unions, enums used by this service
            for (var operation : topDown.getContainedOperations(service)) {
                var inputShape = operationIndex.expectInputShape(operation);
                var outputShape = operationIndex.expectOutputShape(operation);
                writeStructureRecord(writer, inputShape, service, model);
                writer.write("");
                writeStructureRecord(writer, outputShape, service, model);
                writer.write("");
            }

            // Generate error records
            for (var operation : topDown.getContainedOperations(service)) {
                for (var errorId : operation.getErrors()) {
                    var errorShape = model.expectShape(errorId, StructureShape.class);
                    writeStructureRecord(writer, errorShape, service, model);
                    writer.write("");
                }
            }

            // Generate enum types (sorted for deterministic output)
            model.shapes(EnumShape.class)
                .filter(shape -> isInService(shape, service, model))
                .sorted((a, b) -> a.getId().getName(service).compareTo(b.getId().getName(service)))
                .forEach(shape -> {
                    writeEnumType(writer, shape, service);
                    writer.write("");
                });
            model.shapes(IntEnumShape.class)
                .filter(shape -> isInService(shape, service, model))
                .sorted((a, b) -> a.getId().getName(service).compareTo(b.getId().getName(service)))
                .forEach(shape -> {
                    writeIntEnumType(writer, shape, service);
                    writer.write("");
                });

            // Module record
            writer.write("local record M");
            writer.indent();
            for (var operation : topDown.getContainedOperations(service)) {
                var inputName = operationIndex.expectInputShape(operation).getId().getName(service);
                var outputName = operationIndex.expectOutputShape(operation).getId().getName(service);
                writer.write("$L: $L", inputName, inputName);
                writer.write("$L: $L", outputName, outputName);
            }
            writer.dedent();
            writer.write("end");
            writer.write("");
            writer.write("return M");
        });
    }

    private static void generateClientDecl(
            WriterDelegator<LuaWriter> delegator,
            Model model,
            ServiceShape service,
            String serviceNs,
            SymbolProvider symbolProvider
    ) {
        var file = serviceNs + "/client.d.tl";
        delegator.useFileWriter(file, serviceNs, writer -> {
            var topDown = TopDownIndex.of(model);
            var operationIndex = OperationIndex.of(model);

            writer.write("local types = require(\"$L.types\")", serviceNs);
            writer.write("");

            // Client record
            writer.write("local record Client");
            writer.indent();
            for (var operation : topDown.getContainedOperations(service)) {
                var opName = symbolProvider.toSymbol(operation).getName();
                var inputName = operationIndex.expectInputShape(operation).getId().getName(service);
                var outputName = operationIndex.expectOutputShape(operation).getId().getName(service);
                writeDoc(writer, operation);
                writer.write("$L: function(Client, types.$L): types.$L, table",
                        opName, inputName, outputName);
            }
            writer.dedent();
            writer.write("end");
            writer.write("");

            // Module record
            writer.write("local record M");
            writer.indent();
            writer.write("new: function(table): Client");
            writer.dedent();
            writer.write("end");
            writer.write("");
            writer.write("return M");
        });
    }

    private static void writeStructureRecord(LuaWriter writer, StructureShape shape, ServiceShape service, Model model) {
        var name = shape.getId().getName(service);
        writeDoc(writer, shape);
        writer.write("local record $L", name);
        writer.indent();
        for (var member : shape.members()) {
            var target = model.expectShape(member.getTarget());
            String tealType;
            if (member.hasTrait(HttpPayloadTrait.class) && target.hasTrait(StreamingTrait.class)) {
                tealType = "function(): string, string";
            } else {
                tealType = toTealType(target, service, model);
            }
            writeDoc(writer, member);
            writer.write("$L: $L", member.getMemberName(), tealType);
        }
        writer.dedent();
        writer.write("end");
    }

    private static void writeEnumType(LuaWriter writer, EnumShape shape, ServiceShape service) {
        var name = shape.getId().getName(service);
        var values = shape.getEnumValues().values();
        writer.write("local type $L = $L", name,
                String.join(" | ", values.stream().map(v -> "\"" + v + "\"").toList()));
    }

    private static void writeIntEnumType(LuaWriter writer, IntEnumShape shape, ServiceShape service) {
        var name = shape.getId().getName(service);
        var values = shape.getEnumValues().values();
        writer.write("local type $L = $L", name,
                String.join(" | ", values.stream().map(String::valueOf).toList()));
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
