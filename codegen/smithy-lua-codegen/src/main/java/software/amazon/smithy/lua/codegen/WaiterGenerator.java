package software.amazon.smithy.lua.codegen;

import java.util.TreeMap;
import software.amazon.smithy.model.knowledge.TopDownIndex;
import software.amazon.smithy.model.shapes.OperationShape;
import software.amazon.smithy.waiters.Acceptor;
import software.amazon.smithy.waiters.Matcher;
import software.amazon.smithy.waiters.Waiter;
import software.amazon.smithy.waiters.WaitableTrait;

/**
 * Generates {ns}/waiters.lua from @waitable traits on operations.
 * Each waiter becomes a function that calls waiter.wait() with the
 * acceptor config emitted as a Lua table literal.
 */
public final class WaiterGenerator implements LuaIntegration {

    @Override
    public void writeAdditionalFiles(LuaContext context) {
        var model = context.model();
        var service = context.service();
        var serviceNs = LuaSymbolProvider.getServiceNamespace(service);
        var symbolProvider = context.symbolProvider();
        var topDown = TopDownIndex.of(model);

        // Collect all waiters across operations
        var allWaiters = new TreeMap<String, WaiterEntry>();
        for (var operation : topDown.getContainedOperations(service)) {
            operation.getTrait(WaitableTrait.class).ifPresent(trait -> {
                for (var entry : trait.getWaiters().entrySet()) {
                    allWaiters.put(entry.getKey(), new WaiterEntry(
                            entry.getValue(), symbolProvider.toSymbol(operation).getName()));
                }
            });
        }

        if (allWaiters.isEmpty()) return;

        context.writerDelegator().useFileWriter(
                serviceNs + "/waiters.tl", serviceNs, writer -> {
                    writer.addRequire("waiter", "smithy.waiter");
                    writer.write("local M = {}");
                    writer.write("");

                    for (var entry : allWaiters.entrySet()) {
                        writeWaiterFunction(writer, entry.getKey(), entry.getValue());
                        writer.write("");
                    }

                    writer.write("return M");
                });
    }

    private void writeWaiterFunction(LuaWriter writer, String waiterName, WaiterEntry entry) {
        var fnName = toSnakeCase(waiterName);
        var waiter = entry.waiter;

        writer.write("--- Wait until $L.", waiterName);
        writer.block("function M.wait_until_" + fnName + "(client, input, options)", () -> {
            writer.write("return waiter.wait(client, $S, input, {", entry.operationMethodName);
            writer.indent();
            writer.write("min_delay = $L,", waiter.getMinDelay());
            writer.write("max_delay = $L,", waiter.getMaxDelay());
            writer.write("acceptors = {");
            writer.indent();
            for (var acceptor : waiter.getAcceptors()) {
                writeAcceptor(writer, acceptor);
            }
            writer.dedent();
            writer.write("},");
            writer.dedent();
            writer.write("}, options)");
        });
    }

    private void writeAcceptor(LuaWriter writer, Acceptor acceptor) {
        writer.write("{");
        writer.indent();
        writer.write("state = $S,", acceptor.getState().toString());
        writer.write("matcher = {");
        writer.indent();

        acceptor.getMatcher().accept(new Matcher.Visitor<Void>() {
            @Override
            public Void visitOutput(Matcher.OutputMember m) {
                var pm = m.getValue();
                writer.write("output = {");
                writer.indent();
                writer.write("path = $S,", pm.getPath());
                writer.write("expected = $S,", pm.getExpected());
                writer.write("comparator = $S,", pm.getComparator().toString());
                writer.dedent();
                writer.write("},");
                return null;
            }

            @Override
            public Void visitInputOutput(Matcher.InputOutputMember m) {
                var pm = m.getValue();
                writer.write("inputOutput = {");
                writer.indent();
                writer.write("path = $S,", pm.getPath());
                writer.write("expected = $S,", pm.getExpected());
                writer.write("comparator = $S,", pm.getComparator().toString());
                writer.dedent();
                writer.write("},");
                return null;
            }

            @Override
            public Void visitSuccess(Matcher.SuccessMember m) {
                writer.write("success = $L,", m.getValue());
                return null;
            }

            @Override
            public Void visitErrorType(Matcher.ErrorTypeMember m) {
                writer.write("errorType = $S,", m.getValue());
                return null;
            }

            @Override
            public Void visitUnknown(Matcher.UnknownMember m) {
                return null;
            }
        });

        writer.dedent();
        writer.write("},");
        writer.dedent();
        writer.write("},");
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

    private record WaiterEntry(Waiter waiter, String operationMethodName) {}
}
