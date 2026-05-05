-- smithy-lua runtime: retryer interface

local record retry_mod
    record Token
        attempt: integer
        cost: integer
    end

    record Retryer
        acquire_token: function(Retryer): Token, any
        retry_token: function(Retryer, Token, any): number, any
        record_success: function(Retryer, Token)
    end
end

function retry_mod.none(): retry_mod.Retryer
    return {
        acquire_token = function(_self: retry_mod.Retryer): retry_mod.Token, any
            return { attempt = 0 } as retry_mod.Token
        end,
        retry_token = function(_self: retry_mod.Retryer, _token: retry_mod.Token, err: any): number, any
            return nil, err
        end,
        record_success = function(_self: retry_mod.Retryer, _token: retry_mod.Token) end,
    }
end

return retry_mod
