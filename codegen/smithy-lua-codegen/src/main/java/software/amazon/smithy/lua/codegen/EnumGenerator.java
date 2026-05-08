package software.amazon.smithy.lua.codegen;

import software.amazon.smithy.model.shapes.EnumShape;
import software.amazon.smithy.model.shapes.IntEnumShape;
import software.amazon.smithy.model.shapes.Shape;

/**
 * Generates enum type definitions into types.tl.
 */
final class EnumGenerator {

    static void writeEnum(LuaWriter writer, Shape shape, LuaContext context) {
        var enumShape = (EnumShape) shape;
        var name = enumShape.getId().getName(context.service());
        writer.write("enum $L", name);
        writer.indent();
        for (var v : enumShape.getEnumValues().values()) {
            writer.write("\"$L\"", v);
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
