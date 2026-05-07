local record M
end

function M.none(): table
    return {
        acquire_token = function(): table return {} end,
        retry_token = function(_: any, _: any, err: any): number, any return nil as number, err end,
        record_success = function() end,
    }
end

return M
