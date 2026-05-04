package software.amazon.smithy.lua.codegen;

import software.amazon.smithy.build.PluginContext;
import software.amazon.smithy.build.SmithyBuildPlugin;
import software.amazon.smithy.codegen.core.directed.CodegenDirector;

public final class LuaCodegenPlugin implements SmithyBuildPlugin {
    @Override
    public String getName() {
        return "lua-client-codegen";
    }

    @Override
    public void execute(PluginContext context) {
        CodegenDirector<LuaWriter, LuaIntegration, LuaContext, LuaSettings> runner =
                new CodegenDirector<>();

        runner.directedCodegen(new DirectedLuaCodegen());
        runner.integrationClass(LuaIntegration.class);
        runner.fileManifest(context.getFileManifest());
        runner.model(context.getModel());

        LuaSettings settings = runner.settings(LuaSettings.class, context.getSettings());
        runner.service(settings.service());

        runner.performDefaultCodegenTransforms();
        runner.createDedicatedInputsAndOutputs();

        runner.run();
    }
}
