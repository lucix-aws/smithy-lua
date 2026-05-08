package software.amazon.smithy.lua.codegen;

import software.amazon.smithy.model.shapes.EnumShape;
import software.amazon.smithy.model.shapes.Shape;
import software.amazon.smithy.model.traits.EnumTrait;

/**
 * Generates enum type definitions into types.tl.
 */
final class EnumGenerator {

    static void writeEnum(LuaWriter writer, Shape shape, LuaContext context) {
        var name = shape.getId().getName(context.service());
        writer.write("enum $L", name);
        writer.indent();
        if (shape instanceof EnumShape enumShape) {
            for (var v : enumShape.getEnumValues().values()) {
                writer.write("\"$L\"", v);
            }
        } else {
            // Smithy 1.0 string shape with @enum trait
            shape.getTrait(EnumTrait.class).ifPresent(t -> {
                for (var def : t.getValues()) {
                    writer.write("\"$L\"", def.getValue());
                }
            });
        }
        writer.dedent();
        writer.write("end");
        writer.write("");
    }

    static void writeIntEnum(LuaWriter writer, Shape shape, LuaContext context) {
        var name = shape.getId().getName(context.service());
        writer.write("type $L = number", name);
        writer.write("");
    }
}
