package software.amazon.smithy.lua.codegen.util;

import software.amazon.smithy.model.Model;
import software.amazon.smithy.model.shapes.Shape;
import software.amazon.smithy.model.shapes.ShapeId;
import software.amazon.smithy.utils.SmithyInternalApi;

import java.util.HashSet;
import java.util.Set;

@SmithyInternalApi
public final class ShapeUtil {
    public static Set<Shape> getShapesInTree(Model model, Shape shape) {
        var shapes = new HashSet<Shape>();
        visitShapes(model, shape, shapes);
        return shapes;
    }

    private static void visitShapes(Model model, Shape shape, Set<Shape> visited) {
        if (visited.contains(shape)) {
            return;
        }

        visited.add(shape);
        shape.members().stream()
                .filter(it -> !isUnit(it.getTarget()))
                .map(it -> model.expectShape(it.getTarget()))
                .forEach(it -> visitShapes(model, it, visited));
    }

    private static boolean isUnit(ShapeId id) {
        return id.toString().equals("smithy.api#Unit");
    }
}
