local record paginator

    record PaginatorConfig
        input_token: string
        output_token: string
        items: string
        page_size: string
    end

    pages: function(client: table, op_name: string, input: table, config: PaginatorConfig): function(): table, table
    items: function(client: table, op_name: string, input: table, config: PaginatorConfig): function(): any
end

return paginator
