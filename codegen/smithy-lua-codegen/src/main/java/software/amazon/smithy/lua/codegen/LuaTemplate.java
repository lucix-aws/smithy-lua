package software.amazon.smithy.lua.codegen;

import software.amazon.smithy.utils.SmithyInternalApi;

import java.util.Collections;
import java.util.Map;
import java.util.function.Consumer;

import static java.util.Collections.emptyMap;

@SmithyInternalApi
public class LuaTemplate implements Consumer<LuaWriter> {
    private final String content;
    private final Map<String, Object> args;

    public static LuaTemplate of(String content, Map<String, Object> args) {
        return new LuaTemplate(content, args);
    }

    public static LuaTemplate of(String content) {
        return new LuaTemplate(content, emptyMap());
    }

    private LuaTemplate(String content, Map<String, Object> args) {
        this.content = content;
        this.args = args;
    }

    @Override
    public void accept(LuaWriter writer) {
        writer.pushState();
        // TODO
        writer.popState();
    }
}
