package software.amazon.smithy.lua.codegen;

import java.util.TreeMap;
import software.amazon.smithy.model.knowledge.PaginatedIndex;
import software.amazon.smithy.model.knowledge.PaginationInfo;
import software.amazon.smithy.model.knowledge.TopDownIndex;

/**
 * Generates {ns}/paginators.lua from @paginated traits on operations.
 * Each paginated operation gets pages() and items() functions that
 * delegate to the runtime paginator module.
 */
public final class PaginatorGenerator implements LuaIntegration {

    @Override
    public void writeAdditionalFiles(LuaContext context) {
        var model = context.model();
        var service = context.service();
        var serviceNs = LuaSymbolProvider.getServiceNamespace(service);
        var symbolProvider = context.symbolProvider();
        var topDown = TopDownIndex.of(model);
        var paginatedIndex = PaginatedIndex.of(model);

        var allPaginated = new TreeMap<String, PaginationInfo>();
        for (var operation : topDown.getContainedOperations(service)) {
            var info = paginatedIndex.getPaginationInfo(service, operation);
            info.ifPresent(pi -> allPaginated.put(
                    symbolProvider.toSymbol(operation).getName(), pi));
        }

        if (allPaginated.isEmpty()) return;

        context.writerDelegator().useFileWriter(
                serviceNs + "/paginators.lua", serviceNs, writer -> {
                    writer.addRequire("paginator", "smithy.paginator");
                    writer.write("local M = {}");
                    writer.write("");

                    for (var entry : allPaginated.entrySet()) {
                        writePaginatorFunctions(writer, entry.getKey(), entry.getValue());
                        writer.write("");
                    }

                    writer.write("return M");
                });

        context.writerDelegator().useFileWriter(
                serviceNs + "/paginators.d.tl", serviceNs, writer -> {
                    writer.write("local record M");
                    writer.indent();
                    for (var entry : allPaginated.entrySet()) {
                        var fnName = toSnakeCase(entry.getKey());
                        writer.write("pages_$L: function(client: table, input: table): function(): table, table", fnName);
                        if (!entry.getValue().getItemsMemberPath().isEmpty()) {
                            writer.write("items_$L: function(client: table, input: table): function(): any", fnName);
                        }
                    }
                    writer.dedent();
                    writer.write("end");
                    writer.write("");
                    writer.write("return M");
                });
    }

    private void writePaginatorFunctions(LuaWriter writer, String opMethodName, PaginationInfo info) {
        var fnName = toSnakeCase(opMethodName);
        var inputToken = info.getPaginatedTrait().getInputToken().orElse(null);
        var outputToken = info.getPaginatedTrait().getOutputToken().orElse(null);
        if (inputToken == null || outputToken == null) return;

        var items = info.getPaginatedTrait().getItems().orElse(null);

        // pages function
        writer.write("--- Returns a page iterator for $L.", opMethodName);
        writer.block("function M.pages_" + fnName + "(client, input)", () -> {
            writer.write("return paginator.pages(client, $S, input, {", opMethodName);
            writer.indent();
            writer.write("input_token = $S,", inputToken);
            writer.write("output_token = $S,", outputToken);
            if (items != null) {
                writer.write("items = $S,", items);
            }
            writer.dedent();
            writer.write("})");
        });

        // items function (only if items path is defined)
        if (items != null) {
            writer.write("");
            writer.write("--- Returns an item iterator for $L.", opMethodName);
            writer.block("function M.items_" + fnName + "(client, input)", () -> {
                writer.write("return paginator.items(client, $S, input, {", opMethodName);
                writer.indent();
                writer.write("input_token = $S,", inputToken);
                writer.write("output_token = $S,", outputToken);
                writer.write("items = $S,", items);
                writer.dedent();
                writer.write("})");
            });
        }
    }

    private static String toSnakeCase(String pascalCase) {
        var sb = new StringBuilder();
        for (int i = 0; i < pascalCase.length(); i++) {
            char c = pascalCase.charAt(i);
            if (Character.isUpperCase(c) && i > 0) {
                sb.append('_');
            }
            sb.append(Character.toLowerCase(c));
        }
        return sb.toString();
    }
}
