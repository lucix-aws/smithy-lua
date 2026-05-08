local assert = require("luassert") as any
-- Tests for runtime/paginator.lua

local paginator = require("smithy.paginator")

-- Helper: mock client that returns pages from a list
local function mock_client(pages: {{string:any}}): {string:any}
    local idx = 0
    return {
        listThings = function(self: any, input: {string:any}): {string:any}, any
            idx = idx + 1
            if idx > #pages then return nil, { type = "sdk", code = "NoMorePages", message = "bug" } end
            return pages[idx], nil
        end
    }
end

describe("paginator", function()

it("_get_path: nested path", function()
    assert.are.equal("hello", paginator._get_path({ a = { b = "hello" } }, "a.b"))
end)

it("_get_path: single segment", function()
    assert.are.equal("top", paginator._get_path({ a = "top" }, "a"))
end)

it("_get_path: non-table intermediate", function()
    assert.is_nil(paginator._get_path({ a = 1 }, "a.b"))
end)

it("_get_path: missing key", function()
    assert.is_nil(paginator._get_path({}, "x"))
end)

it("pages: 3 pages returned", function()
    local client = mock_client({
        { Items = { "a", "b" }, NextToken = "tok1" },
        { Items = { "c" }, NextToken = "tok2" },
        { Items = { "d" }, NextToken = nil },
    })
    local config = { input_token = "NextToken", output_token = "NextToken", items = "Items" }
    local results: {{string:any}} = {}
    for output in paginator.pages(client, "listThings", {}, config) do
        results[#results + 1] = output
    end
    assert.are.equal(3, #results)
    assert.are.equal("tok1", results[1].NextToken)
    assert.are.equal(nil, results[3].NextToken)
end)

it("pages: stops on empty string token", function()
    local client = mock_client({
        { Items = { "a" }, NextToken = "" },
    })
    local config = { input_token = "NextToken", output_token = "NextToken", items = "Items" }
    local results: {{string:any}} = {}
    for output in paginator.pages(client, "listThings", {}, config) do
        results[#results + 1] = output
    end
    assert.are.equal(1, #results)
end)

it("pages: stops on duplicate token", function()
    local call_count = 0
    local client = {
        listThings = function(self: any, input: {string:any}): {string:any}, any
            call_count = call_count + 1
            return { Items = { "x" }, NextToken = "same" }, nil
        end
    }
    local config = { input_token = "NextToken", output_token = "NextToken", items = "Items" }
    local results: {{string:any}} = {}
    for output in paginator.pages(client, "listThings", {}, config) do
        results[#results + 1] = output
    end
    assert.are.equal(2, #results)
end)

it("pages: error propagation", function()
    local client = {
        listThings = function(self: any, input: {string:any}): {string:any}, any
            return nil, { type = "api", code = "Boom", message = "exploded" }
        end
    }
    local config = { input_token = "NextToken", output_token = "NextToken" }
    local iter = paginator.pages(client, "listThings", {}, config)
    local output, err = iter()
    assert.is_nil(output)
    assert.are.equal("Boom", (err as {string:string}).code)
end)

it("pages: input token injection", function()
    local captured_inputs: {{string:any}} = {}
    local call_count = 0
    local client = {
        listThings = function(self: any, input: {string:any}): {string:any}, any
            call_count = call_count + 1
            captured_inputs[call_count] = input
            if call_count == 1 then
                return { NextToken = "page2" }, nil
            else
                return { NextToken = nil }, nil
            end
        end
    }
    local config = { input_token = "NextToken", output_token = "NextToken" }
    for _ in paginator.pages(client, "listThings", { Filter = "active" }, config) do end
    assert.are.equal(2, call_count)
    assert.is_nil(captured_inputs[1].NextToken)
    assert.are.equal("page2", captured_inputs[2].NextToken)
    assert.are.equal("active", captured_inputs[2].Filter)
end)

it("pages: no input mutation", function()
    local original = { Filter = "x" }
    local client = mock_client({
        { NextToken = "t1" },
        { NextToken = nil },
    })
    local config = { input_token = "NextToken", output_token = "NextToken" }
    for _ in paginator.pages(client, "listThings", original, config) do end
    assert.is_nil((original as {string:any}).NextToken)
end)

it("items: flatten across pages", function()
    local client = mock_client({
        { Items = { "a", "b" }, NextToken = "tok1" },
        { Items = { "c" }, NextToken = "tok2" },
        { Items = { "d", "e" }, NextToken = nil },
    })
    local config = { input_token = "NextToken", output_token = "NextToken", items = "Items" }
    local all: {string} = {}
    for item in paginator.items(client, "listThings", {}, config) do
        all[#all + 1] = item as string
    end
    assert.are.equal(5, #all)
    assert.are.equal("a", all[1])
    assert.are.equal("e", all[5])
end)

it("items: nested path", function()
    local client = mock_client({
        { result = { things = { "x", "y" } }, NextToken = "t1" },
        { result = { things = { "z" } }, NextToken = nil },
    })
    local config = { input_token = "NextToken", output_token = "NextToken", items = "result.things" }
    local all: {string} = {}
    for item in paginator.items(client, "listThings", {}, config) do
        all[#all + 1] = item as string
    end
    assert.are.equal(3, #all)
    assert.are.equal("x", all[1])
end)

it("items: empty page", function()
    local client = mock_client({
        { Items = {}, NextToken = "t1" },
        { Items = { "a" }, NextToken = nil },
    })
    local config = { input_token = "NextToken", output_token = "NextToken", items = "Items" }
    local all: {string} = {}
    for item in paginator.items(client, "listThings", {}, config) do
        all[#all + 1] = item as string
    end
    assert.are.equal(1, #all)
    assert.are.equal("a", all[1])
end)

it("pages: nested output token", function()
    local captured_inputs: {{string:any}} = {}
    local call_count = 0
    local client = {
        listThings = function(self: any, input: {string:any}): {string:any}, any
            call_count = call_count + 1
            captured_inputs[call_count] = input
            if call_count == 1 then
                return { pagination = { cursor = "abc" } }, nil
            else
                return { pagination = { cursor = nil } }, nil
            end
        end
    }
    local config = { input_token = "Cursor", output_token = "pagination.cursor" }
    for _ in paginator.pages(client, "listThings", {}, config) do end
    assert.are.equal(2, call_count)
    assert.are.equal("abc", captured_inputs[2].Cursor)
end)

end)
