package software.amazon.smithy.lua.codegen.client;

import software.amazon.smithy.lua.codegen.LuaCodegenContext;
import software.amazon.smithy.lua.codegen.LuaWriter;
import software.amazon.smithy.model.knowledge.TopDownIndex;
import software.amazon.smithy.model.shapes.OperationShape;

import java.util.function.Consumer;

// FIXME: assumes awsJson1_0
public class ServiceClient implements Consumer<LuaWriter> {
    public final LuaCodegenContext ctx;

    public ServiceClient(LuaCodegenContext ctx) {
        this.ctx = ctx;
    }

    @Override
    public void accept(LuaWriter writer) {
        writer.write("local http = require('./runtime/http')");
        writer.write("local json = require('./runtime/json')");
        writer.write("local sigv4 = require('./runtime/sigv4')");

        writer.write("local Client = {}");
        writer.write("");

        renderDo(writer);

        renderNew(writer);

        TopDownIndex.of(ctx.model()).getContainedOperations(ctx.settings().getService()).forEach(it -> {
            renderOperation(writer, it);
        });

        writer.write("return Client");
    }

    private void renderNew(LuaWriter writer) {
        writer.write("""
                function Client:New(config)
                    local t = {
                        _config = {
                            Region      = config.Region,
                            Credentials = config.Credentials,
                            HTTPClient  = config.HTTPClient,
                        },
                    }
                    setmetatable(t, self)
                    self.__index = self

                    return t
                end
                """);
    }

    private void renderOperation(LuaWriter writer, OperationShape operation) {
        var name = operation.getId().getName();
        var target = ctx.settings().getService().getName() + "." + name;
        writer.write("""
                function Client:$L(input)
                    return _do(self, input, $S)
                end
                """, name, target);
    }

    private void renderDo(LuaWriter writer) {
        writer.write("""
                local function _do(client, input, target)
                    local req = http.Request:New()

                    local endpoint = 'https://sqs.'..client._config.Region..'.amazonaws.com'
                    req.URL = endpoint
                    req.Host = 'sqs.'..client._config.Region..'.amazonaws.com'

                    req.Method = 'POST'
                    req.Header:Set("Content-Type", "application/x-amz-json-1.0")
                    req.Header:Set("X-Amz-Target", target)
                    req.Body = json.encode(input)

                    sigv4.Sign(req, client._config.Credentials, 'sqs', client._config.Region)

                    local resp = client._config.HTTPClient:Do(req)
                    return json.decode(resp.Body), nil
                end
                """);
    }
}
