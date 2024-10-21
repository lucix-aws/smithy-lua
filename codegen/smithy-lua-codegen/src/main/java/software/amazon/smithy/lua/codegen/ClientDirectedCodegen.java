package software.amazon.smithy.lua.codegen;

import software.amazon.smithy.codegen.core.SymbolProvider;
import software.amazon.smithy.codegen.core.WriterDelegator;
import software.amazon.smithy.codegen.core.directed.CreateContextDirective;
import software.amazon.smithy.codegen.core.directed.CreateSymbolProviderDirective;
import software.amazon.smithy.codegen.core.directed.DirectedCodegen;
import software.amazon.smithy.codegen.core.directed.GenerateEnumDirective;
import software.amazon.smithy.codegen.core.directed.GenerateErrorDirective;
import software.amazon.smithy.codegen.core.directed.GenerateIntEnumDirective;
import software.amazon.smithy.codegen.core.directed.GenerateServiceDirective;
import software.amazon.smithy.codegen.core.directed.GenerateStructureDirective;
import software.amazon.smithy.codegen.core.directed.GenerateUnionDirective;


public final class ClientDirectedCodegen implements DirectedCodegen<LuaCodegenContext, LuaSettings, LuaIntegration> {
    @Override
    public SymbolProvider createSymbolProvider(CreateSymbolProviderDirective<LuaSettings> createSymbolProviderDirective) {
        return null;
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
    }

    @Override
    public void generateStructure(GenerateStructureDirective<LuaCodegenContext, LuaSettings> generateStructureDirective) {

    }

    @Override
    public void generateError(GenerateErrorDirective<LuaCodegenContext, LuaSettings> generateErrorDirective) {

    }

    @Override
    public void generateUnion(GenerateUnionDirective<LuaCodegenContext, LuaSettings> generateUnionDirective) {

    }

    @Override
    public void generateEnumShape(GenerateEnumDirective<LuaCodegenContext, LuaSettings> generateEnumDirective) {

    }

    @Override
    public void generateIntEnumShape(GenerateIntEnumDirective<LuaCodegenContext, LuaSettings> generateIntEnumDirective) {

    }
}