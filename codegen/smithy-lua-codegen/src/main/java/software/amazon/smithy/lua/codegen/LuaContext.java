package software.amazon.smithy.lua.codegen;

import java.util.List;
import software.amazon.smithy.codegen.core.CodegenContext;
import software.amazon.smithy.codegen.core.SymbolProvider;
import software.amazon.smithy.codegen.core.WriterDelegator;
import software.amazon.smithy.model.Model;
import software.amazon.smithy.model.shapes.ServiceShape;
import software.amazon.smithy.build.FileManifest;

public record LuaContext(
        Model model,
        LuaSettings settings,
        SymbolProvider symbolProvider,
        FileManifest fileManifest,
        WriterDelegator<LuaWriter> writerDelegator,
        List<LuaIntegration> integrations,
        ServiceShape service
) implements CodegenContext<LuaSettings, LuaWriter, LuaIntegration> {
}
