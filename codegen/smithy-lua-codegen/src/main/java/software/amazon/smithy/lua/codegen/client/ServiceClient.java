package software.amazon.smithy.lua.codegen.client;

import software.amazon.smithy.lua.codegen.LuaCodegenContext;
import software.amazon.smithy.lua.codegen.LuaWriter;
import software.amazon.smithy.model.knowledge.TopDownIndex;
import software.amazon.smithy.model.shapes.OperationShape;

import java.util.function.Consumer;

public class ServiceClient implements Consumer<LuaWriter> {
    public final LuaCodegenContext ctx;

    public ServiceClient(LuaCodegenContext ctx) {
        this.ctx = ctx;
    }

    @Override
    public void accept(LuaWriter writer) {
        writer.write("local Client = {}");
        writer.write("");

        renderNew(writer);

        TopDownIndex.of(ctx.model()).getContainedOperations(ctx.settings().getService()).forEach(it -> {
            renderOperation(writer, it);
        });

        renderDo(writer);

        writer.write("return Client");
    }

    private void renderNew(LuaWriter writer) {
        writer.write("function Client:New(config)");
        writer.write("end");
    }

    private void renderOperation(LuaWriter writer, OperationShape operation) {
        writer.write("function Client:$L(input)", operation.getId().getName());
        writer.write("end");
        writer.write("");
    }

    private void renderDo(LuaWriter writer) {
        writer.write("""
                local function do(client, input)
                end
                """);
    }
}
