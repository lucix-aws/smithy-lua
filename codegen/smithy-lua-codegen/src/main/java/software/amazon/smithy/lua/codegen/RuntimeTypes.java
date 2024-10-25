package software.amazon.smithy.lua.codegen;

import software.amazon.smithy.codegen.core.Symbol;

public final class RuntimeTypes {
    public static class Http {
        private static Symbol buildSymbol(String name) { return RuntimeTypes.buildSymbol(name, "http", "runtime/http"); }

        public static Symbol Client = buildSymbol("Client");
        public static Symbol Request = buildSymbol("Request");
    }

    public static class Json {
        private static Symbol buildSymbol(String name) { return RuntimeTypes.buildSymbol(name, "json", "runtime/json"); }

        public static Symbol Decode = buildSymbol("decode");
        public static Symbol Encode = buildSymbol("encode");
    }

    public static class Sigv4 {
        private static Symbol buildSymbol(String name) { return RuntimeTypes.buildSymbol(name, "sigv4", "runtime/sigv4"); }

        public static Symbol Credentials = buildSymbol("Credentials");
        public static Symbol Sign = buildSymbol("Sign");
    }

    private static Symbol buildSymbol(String name, String namespace, String module) {
        return Symbol.builder()
                .name(name)
                .namespace(namespace, ".")
                .definitionFile(module)
                .build();
    }
}
