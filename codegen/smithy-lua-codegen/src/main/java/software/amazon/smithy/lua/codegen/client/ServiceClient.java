package software.amazon.smithy.lua.codegen.client;

import software.amazon.smithy.lua.codegen.LuaCodegenContext;
import software.amazon.smithy.lua.codegen.LuaWriter;
import software.amazon.smithy.model.knowledge.TopDownIndex;

import java.util.function.Consumer;

public class ServiceClient implements Consumer<LuaWriter> {
    public final LuaCodegenContext ctx;

    public ServiceClient(LuaCodegenContext ctx) {
        this.ctx = ctx;
    }

    @Override
    public void accept(LuaWriter writer) {
        writer.write("local module = {}");

        TopDownIndex.of(ctx.model()).getContainedOperations(ctx.settings().getService()).forEach(it -> {
            writer.write("function module.$S()", it.getId().getName());
            writer.write("end");
            writer.write("");
        });

        writer.write("return module");
    }
}
