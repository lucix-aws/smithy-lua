package software.amazon.smithy.lua.codegen.integration;

import software.amazon.smithy.lua.codegen.LuaCodegenContext;
import software.amazon.smithy.lua.codegen.LuaIntegration;
import software.amazon.smithy.lua.codegen.LuaWriter;
import software.amazon.smithy.lua.codegen.RuntimeTypes;
import software.amazon.smithy.model.knowledge.TopDownIndex;
import software.amazon.smithy.model.shapes.CollectionShape;
import software.amazon.smithy.model.shapes.MapShape;
import software.amazon.smithy.model.shapes.Shape;
import software.amazon.smithy.model.shapes.StructureShape;
import software.amazon.smithy.utils.SmithyInternalApi;

import java.util.stream.Stream;

import static java.util.stream.Collectors.toSet;
import static software.amazon.smithy.lua.codegen.util.ShapeUtil.getShapesInTree;

@SmithyInternalApi
public class TealTypes implements LuaIntegration {
    @Override
    public void writeAdditionalSource(LuaCodegenContext ctx) {
        var model = ctx.model();
        var service = ctx.settings().getService();
        var operations = TopDownIndex.of(model).getContainedOperations(service);

        // follow the tree of every input and output shape to find everything that needs a type decl
        var shapes = Stream.concat(
                operations.stream()
                        .flatMap(it -> getShapesInTree(model, model.expectShape(it.getInputShape())).stream()),
                operations.stream()
                        .flatMap(it -> getShapesInTree(model, model.expectShape(it.getOutputShape())).stream())
        ).collect(toSet());

        ctx.writerDelegator().useFileWriter("client.d.tl", writer -> {
            writer.openBlock("local record module", "end", () -> {
                shapes.forEach(it -> renderType(ctx, writer, it));
                writer.write("");

                writer.openBlock("record Config", "end", () -> {
                    writer.write("Region: string");
                    writer.write("Credentials: $T", RuntimeTypes.Sigv4.Credentials);
                    writer.write("HTTPClient: $T", RuntimeTypes.Http.Client);
                });
                writer.write("New: function(config: Config): module");
                operations.forEach(it -> {
                    writer.write("$L: function(self, input: $L): $L",
                            it.getId().getName(), it.getInputShape().getName(), it.getOutputShape().getName());
                });
            });
            writer.write("return module");
        });
    }

    private void renderType(LuaCodegenContext ctx, LuaWriter writer, Shape shape) {
        switch (shape.getType()) {
            // TODO: union?
            case STRUCTURE -> renderRecord(ctx, writer, (StructureShape) shape);
        }
    }

    private void renderRecord(LuaCodegenContext ctx, LuaWriter writer, StructureShape shape) {
        var model = ctx.model();
        writer.openBlock("record $L", "end", shape.getId().getName(), () -> {
            shape.getAllMembers().forEach((name, member) -> {
                var target = model.expectShape(member.getTarget());
                writer.write("$L: $L", name, getType(ctx, target));
            });
        });
    }

    // TODO: nested collections may be weird and teal may have a better way to do those
    private String getType(LuaCodegenContext ctx, Shape shape) {
        var model = ctx.model();
        return switch (shape.getType()) {
            case BYTE, SHORT, INTEGER, LONG, FLOAT, DOUBLE, INT_ENUM -> "number";
            case STRING, ENUM -> "string";
            case LIST, SET -> {
                var target = model.expectShape(((CollectionShape) shape).getMember().getTarget());
                yield "{" + getType(ctx, target) + "}";
            }
            case MAP -> {
                var target = model.expectShape(((MapShape) shape).getValue().getTarget());
                yield "{string: " + getType(ctx, target) + "}";
            }
            case STRUCTURE -> shape.getId().getName();
            // TODO: union
            default -> "any";
        };
    }
}
