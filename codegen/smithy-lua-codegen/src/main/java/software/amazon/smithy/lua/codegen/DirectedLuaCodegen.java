package software.amazon.smithy.lua.codegen;

import java.util.logging.Logger;
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

public final class DirectedLuaCodegen
        implements DirectedCodegen<LuaContext, LuaSettings, LuaIntegration> {

    private static final Logger LOGGER = Logger.getLogger(DirectedLuaCodegen.class.getName());

    @Override
    public SymbolProvider createSymbolProvider(CreateSymbolProviderDirective<LuaSettings> directive) {
        return new LuaSymbolProvider(directive.model(), directive.service());
    }

    @Override
    public LuaContext createContext(CreateContextDirective<LuaSettings, LuaIntegration> directive) {
        return new LuaContext(
                directive.model(),
                directive.settings(),
                directive.symbolProvider(),
                directive.fileManifest(),
                new WriterDelegator<>(directive.fileManifest(),
                        directive.symbolProvider(),
                        (filename, namespace) -> new LuaWriter(namespace)),
                directive.integrations(),
                directive.service()
        );
    }

    @Override
    public void generateService(GenerateServiceDirective<LuaContext, LuaSettings> directive) {
        LOGGER.info("Generating service: " + directive.shape().getId());
        // TODO: generate client module
    }

    @Override
    public void generateStructure(GenerateStructureDirective<LuaContext, LuaSettings> directive) {
        LOGGER.info("Generating structure: " + directive.shape().getId());
        // TODO: generate schema for structure
    }

    @Override
    public void generateError(GenerateErrorDirective<LuaContext, LuaSettings> directive) {
        LOGGER.info("Generating error: " + directive.shape().getId());
        // TODO: generate error schema
    }

    @Override
    public void generateUnion(GenerateUnionDirective<LuaContext, LuaSettings> directive) {
        LOGGER.info("Generating union: " + directive.shape().getId());
        // TODO: generate union schema
    }

    @Override
    public void generateEnumShape(GenerateEnumDirective<LuaContext, LuaSettings> directive) {
        LOGGER.info("Generating enum: " + directive.shape().getId());
        // TODO: generate enum
    }

    @Override
    public void generateIntEnumShape(GenerateIntEnumDirective<LuaContext, LuaSettings> directive) {
        LOGGER.info("Generating int enum: " + directive.shape().getId());
        // TODO: generate int enum
    }
}
