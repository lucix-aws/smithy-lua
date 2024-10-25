package software.amazon.smithy.lua.codegen.client;

import software.amazon.smithy.codegen.core.SymbolProvider;
import software.amazon.smithy.codegen.core.WriterDelegator;
import software.amazon.smithy.codegen.core.directed.CreateContextDirective;
import software.amazon.smithy.codegen.core.directed.CreateSymbolProviderDirective;
import software.amazon.smithy.codegen.core.directed.CustomizeDirective;
import software.amazon.smithy.codegen.core.directed.DirectedCodegen;
import software.amazon.smithy.codegen.core.directed.GenerateEnumDirective;
import software.amazon.smithy.codegen.core.directed.GenerateErrorDirective;
import software.amazon.smithy.codegen.core.directed.GenerateIntEnumDirective;
import software.amazon.smithy.codegen.core.directed.GenerateServiceDirective;
import software.amazon.smithy.codegen.core.directed.GenerateStructureDirective;
import software.amazon.smithy.codegen.core.directed.GenerateUnionDirective;
import software.amazon.smithy.lua.codegen.LuaCodegenContext;
import software.amazon.smithy.lua.codegen.LuaIntegration;
import software.amazon.smithy.lua.codegen.LuaSettings;
import software.amazon.smithy.lua.codegen.LuaSymbolProvider;
import software.amazon.smithy.lua.codegen.LuaWriter;
import software.amazon.smithy.utils.SmithyInternalApi;

@SmithyInternalApi
public final class ClientDirectedCodegen implements DirectedCodegen<LuaCodegenContext, LuaSettings, LuaIntegration> {
    @Override
    public SymbolProvider createSymbolProvider(CreateSymbolProviderDirective<LuaSettings> createSymbolProviderDirective) {
        return new LuaSymbolProvider();
    }

    @Override
    public LuaCodegenContext createContext(CreateContextDirective<LuaSettings, LuaIntegration> directive) {
        return new LuaCodegenContext(
                directive.model(),
                directive.settings(),
                directive.symbolProvider(),
                directive.fileManifest(),
                new WriterDelegator<>(directive.fileManifest(), directive.symbolProvider(),
                        (filename, namespace) -> new LuaWriter()),
                directive.integrations()
        );
    }

    @Override
    public void generateService(GenerateServiceDirective<LuaCodegenContext, LuaSettings> directive) {
        var ctx = directive.context();
        ctx.writerDelegator().useFileWriter("client.lua", ctx.settings().getNamespace(),
                new ServiceClient(ctx));
    }

    @Override
    public void generateStructure(GenerateStructureDirective<LuaCodegenContext, LuaSettings> directive) {
    }

    @Override
    public void generateError(GenerateErrorDirective<LuaCodegenContext, LuaSettings> directive) {
    }

    @Override
    public void generateUnion(GenerateUnionDirective<LuaCodegenContext, LuaSettings> directive) {
    }

    @Override
    public void generateEnumShape(GenerateEnumDirective<LuaCodegenContext, LuaSettings> directive) {
    }

    @Override
    public void generateIntEnumShape(GenerateIntEnumDirective<LuaCodegenContext, LuaSettings> generateIntEnumDirective) {
    }

    @Override
    public void customizeBeforeShapeGeneration(CustomizeDirective<LuaCodegenContext, LuaSettings> directive) {
        directive.context().integrations().forEach(it -> {
            it.writeAdditionalSource(directive.context());
        });
    }
}