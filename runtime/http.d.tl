local record module
    interface Client
        Do: function(Request): Response
    end

    record Request
        URL: string
        Host: string
        Method: string
        Header: Header
        Body: string
    end

    record Response -- TODO: header
        StatusCode: number
        Body: string
    end

    record Header
        _values: {string: string}
        Get: function(self, name: string): string
        Set: function(self, name: string, value: string)
    end
end

return module
