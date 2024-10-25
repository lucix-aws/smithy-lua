package software.amazon.smithy.lua.codegen.client;

import software.amazon.smithy.aws.traits.ServiceTrait;
import software.amazon.smithy.aws.traits.auth.SigV4Trait;
import software.amazon.smithy.lua.codegen.LuaCodegenContext;
import software.amazon.smithy.lua.codegen.LuaTemplate;
import software.amazon.smithy.lua.codegen.LuaWriter;
import software.amazon.smithy.lua.codegen.RuntimeTypes;
import software.amazon.smithy.model.knowledge.TopDownIndex;
import software.amazon.smithy.model.shapes.OperationShape;
import software.amazon.smithy.model.shapes.ServiceShape;
import software.amazon.smithy.utils.SmithyInternalApi;

import java.util.Map;
import java.util.function.Consumer;

// TODO: assumes awsJson1_0
// TODO: assumes sigv4
// TODO: assumes basic endpoint scheme & aws.api#service for endpointPrefix
@SmithyInternalApi
public class ServiceClient implements Consumer<LuaWriter> {
    private final LuaCodegenContext ctx;
    private final ServiceShape service;

    public ServiceClient(LuaCodegenContext ctx) {
        this.ctx = ctx;
        this.service = ctx.model().expectShape(ctx.settings().getService(), ServiceShape.class);
    }

    @Override
    public void accept(LuaWriter writer) {
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
                function Client.New(config)
                    return setmetatable({
                        _config = {
                            Region      = config.Region,
                            Credentials = config.Credentials,
                            HTTPClient  = config.HTTPClient,
                        },
                    }, { __index = Client })
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
        var endpointPrefix = service.expectTrait(ServiceTrait.class).getEndpointPrefix();
        var signingName = service.expectTrait(SigV4Trait.class).getName();

        var tmpl = LuaTemplate.of("""
                local function _do(client, input, target)
                    local req = $http.request:T.New()

                    local endpoint = 'https://$ep:L.'..client._config.Region..'.amazonaws.com'
                    req.URL = endpoint
                    req.Host = '$ep:L.'..client._config.Region..'.amazonaws.com'

                    req.Method = 'POST'
                    req.Header:Set("Content-Type", "application/x-amz-json-1.0")
                    req.Header:Set("X-Amz-Target", target)

                    -- https://github.com/rxi/json.lua/issues/23
                    -- empty tables encode as [] which awsJson will not accept, so do it ourselves instead
                    if #input == 0 then
                        req.Body = '{}'
                    else
                        req.Body = $json.encode:T(input)
                    end

                    $sigv4.sign:T(req, client._config.Credentials, $sn:S, client._config.Region)

                    local resp = client._config.HTTPClient:Do(req)
                    return $json.decode:T(resp.Body), nil
                end
                """,
                Map.of(
                        "ep", endpointPrefix,
                        "sn", signingName,
                        "http.request", RuntimeTypes.Http.Request,
                        "json.decode", RuntimeTypes.Json.Decode,
                        "json.encode", RuntimeTypes.Json.Encode,
                        "sigv4.sign", RuntimeTypes.Sigv4.Sign
                ));
        tmpl.accept(writer);
    }
}
