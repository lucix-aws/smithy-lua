package software.amazon.smithy.lua.codegen;

import software.amazon.smithy.build.FileManifest;
import software.amazon.smithy.codegen.core.CodegenContext;
import software.amazon.smithy.codegen.core.SymbolProvider;
import software.amazon.smithy.codegen.core.WriterDelegator;
import software.amazon.smithy.model.Model;

import java.util.List;

public record LuaCodegenContext(
        Model model,
        LuaSettings settings,
        SymbolProvider symbolProvider,
        FileManifest fileManifest,
        WriterDelegator<LuaWriter> writerDelegator,
        List<LuaIntegration> integrations
) implements CodegenContext<LuaSettings, LuaWriter, LuaIntegration> {}

