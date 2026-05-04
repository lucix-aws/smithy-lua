package software.amazon.smithy.lua.codegen;

import software.amazon.smithy.model.node.ObjectNode;
import software.amazon.smithy.model.shapes.ShapeId;

public final class LuaSettings {
    private ShapeId service;

    public static LuaSettings from(ObjectNode config) {
        var settings = new LuaSettings();
        config.getStringMember("service").ifPresent(s ->
                settings.setService(ShapeId.from(s.getValue())));
        return settings;
    }

    public ShapeId service() {
        return service;
    }

    public void setService(ShapeId service) {
        this.service = service;
    }
}
