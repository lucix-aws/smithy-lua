package software.amazon.smithy.lua.codegen;

import software.amazon.smithy.model.node.ObjectNode;
import software.amazon.smithy.model.shapes.ShapeId;
import software.amazon.smithy.utils.SmithyInternalApi;

@SmithyInternalApi
public final class LuaSettings {
    private final ShapeId service;

    @SmithyInternalApi
    public static LuaSettings from(ObjectNode node) {
        return new LuaSettings(
                ShapeId.from(node.expectStringMember("service").getValue())
        );
    }

    private LuaSettings(ShapeId service) {
        this.service = service;
    }

    public ShapeId getService() {
        return this.service;
    }

    public String getNamespace() {
        return "";
    }
}
