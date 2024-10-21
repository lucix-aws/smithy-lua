package software.amazon.smithy.lua.codegen;

import software.amazon.smithy.model.shapes.ShapeId;
import software.amazon.smithy.utils.SmithyInternalApi;

@SmithyInternalApi
public final class LuaSettings {
    public ShapeId getService() {
        return ShapeId.from("");
    }

    public String getNamespace() {
        return "";
    }
}
