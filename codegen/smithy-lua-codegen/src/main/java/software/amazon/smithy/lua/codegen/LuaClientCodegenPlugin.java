package software.amazon.smithy.lua.codegen;

import software.amazon.smithy.build.PluginContext;
import software.amazon.smithy.build.SmithyBuildPlugin;
import software.amazon.smithy.codegen.core.directed.CodegenDirector;

public final class LuaClientCodegenPlugin implements SmithyBuildPlugin {
    @Override
    public String getName() {
        return "lua-client-codegen";
    }

    @Override
    public void execute(PluginContext context) {
        CodegenDirector<LuaWriter, LuaIntegration, LuaCodegenContext, LuaSettings> runner =
                new CodegenDirector<>();

        runner.model(context.getModel());
        runner.directedCodegen(new ClientDirectedCodegen());

        runner.integrationClass(LuaIntegration.class);

        runner.fileManifest(context.getFileManifest());

        var settings = LuaSettings.from(context.getSettings());
        runner.settings(settings);

        runner.service(settings.getService());

        runner.performDefaultCodegenTransforms();
        runner.createDedicatedInputsAndOutputs();
        runner.changeStringEnumsToEnumShapes(false);

        runner.run();
    }
}
