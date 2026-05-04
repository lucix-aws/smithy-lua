-- Tests for runtime/paginator.lua

package.path = "runtime/?.lua;" .. package.path

local paginator = require("smithy.paginator")

local pass, fail = 0, 0
local function assert_eq(a, b, msg)
    if a == b then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. msg .. " expected=" .. tostring(b) .. " got=" .. tostring(a)) end
end

local function assert_nil(a, msg)
    if a == nil then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. msg .. " expected nil, got=" .. tostring(a)) end
end

-- Helper: mock client that returns pages from a list
local function mock_client(pages)
    local idx = 0
    return {
        listThings = function(self, input)
            idx = idx + 1
            if idx > #pages then return nil, { type = "sdk", code = "NoMorePages", message = "bug" } end
            return pages[idx], nil
        end
    }
end

-- Test: _get_path
print("--- _get_path ---")
assert_eq(paginator._get_path({ a = { b = "hello" } }, "a.b"), "hello", "nested path")
assert_eq(paginator._get_path({ a = "top" }, "a"), "top", "single segment")
assert_nil(paginator._get_path({ a = 1 }, "a.b"), "non-table intermediate")
assert_nil(paginator._get_path({}, "x"), "missing key")

-- Test: pages() with 3 pages
print("--- pages: 3 pages ---")
do
    local client = mock_client({
        { Items = { "a", "b" }, NextToken = "tok1" },
        { Items = { "c" }, NextToken = "tok2" },
        { Items = { "d" }, NextToken = nil },
    })
    local config = { input_token = "NextToken", output_token = "NextToken", items = "Items" }
    local results = {}
    for output in paginator.pages(client, "listThings", {}, config) do
        results[#results + 1] = output
    end
    assert_eq(#results, 3, "3 pages returned")
    assert_eq(results[1].NextToken, "tok1", "page 1 token")
    assert_eq(results[3].NextToken, nil, "page 3 no token")
end

-- Test: pages() stops on empty string token
print("--- pages: empty string token ---")
do
    local client = mock_client({
        { Items = { "a" }, NextToken = "" },
    })
    local config = { input_token = "NextToken", output_token = "NextToken", items = "Items" }
    local results = {}
    for output in paginator.pages(client, "listThings", {}, config) do
        results[#results + 1] = output
    end
    assert_eq(#results, 1, "stops on empty token")
end

-- Test: pages() stops on duplicate token
print("--- pages: duplicate token ---")
do
    local call_count = 0
    local client = {
        listThings = function(self, input)
            call_count = call_count + 1
            return { Items = { "x" }, NextToken = "same" }, nil
        end
    }
    local config = { input_token = "NextToken", output_token = "NextToken", items = "Items" }
    local results = {}
    for output in paginator.pages(client, "listThings", {}, config) do
        results[#results + 1] = output
    end
    -- First call: token="same", prev=nil -> continue. Second call: token="same", prev="same" -> stop.
    assert_eq(#results, 2, "stops on duplicate token")
end

-- Test: pages() propagates error
-- The iterator returns nil,err — a generic for loop stops on nil first return,
-- so callers must use a while loop or check the second return after the loop.
print("--- pages: error propagation ---")
do
    local client = {
        listThings = function(self, input)
            return nil, { type = "api", code = "Boom", message = "exploded" }
        end
    }
    local config = { input_token = "NextToken", output_token = "NextToken" }
    local iter = paginator.pages(client, "listThings", {}, config)
    local output, err = iter()
    assert_nil(output, "nil output on error")
    assert_eq(err.code, "Boom", "error code propagated")
end

-- Test: pages() passes input_token to next call
print("--- pages: input token injection ---")
do
    local captured_inputs = {}
    local call_count = 0
    local client = {
        listThings = function(self, input)
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
    assert_eq(call_count, 2, "two calls made")
    assert_nil(captured_inputs[1].NextToken, "first call has no token")
    assert_eq(captured_inputs[2].NextToken, "page2", "second call has token")
    assert_eq(captured_inputs[2].Filter, "active", "original params preserved")
end

-- Test: pages() does not mutate original input
print("--- pages: no input mutation ---")
do
    local original = { Filter = "x" }
    local client = mock_client({
        { NextToken = "t1" },
        { NextToken = nil },
    })
    local config = { input_token = "NextToken", output_token = "NextToken" }
    for _ in paginator.pages(client, "listThings", original, config) do end
    assert_nil(original.NextToken, "original input not mutated")
end

-- Test: items() flattens across pages
print("--- items: flatten across pages ---")
do
    local client = mock_client({
        { Items = { "a", "b" }, NextToken = "tok1" },
        { Items = { "c" }, NextToken = "tok2" },
        { Items = { "d", "e" }, NextToken = nil },
    })
    local config = { input_token = "NextToken", output_token = "NextToken", items = "Items" }
    local all = {}
    for item in paginator.items(client, "listThings", {}, config) do
        all[#all + 1] = item
    end
    assert_eq(#all, 5, "5 items total")
    assert_eq(all[1], "a", "first item")
    assert_eq(all[5], "e", "last item")
end

-- Test: items() with nested items path
print("--- items: nested path ---")
do
    local client = mock_client({
        { result = { things = { "x", "y" } }, NextToken = "t1" },
        { result = { things = { "z" } }, NextToken = nil },
    })
    local config = { input_token = "NextToken", output_token = "NextToken", items = "result.things" }
    local all = {}
    for item in paginator.items(client, "listThings", {}, config) do
        all[#all + 1] = item
    end
    assert_eq(#all, 3, "3 items from nested path")
    assert_eq(all[1], "x", "first nested item")
end

-- Test: items() with empty page
print("--- items: empty page ---")
do
    local client = mock_client({
        { Items = {}, NextToken = "t1" },
        { Items = { "a" }, NextToken = nil },
    })
    local config = { input_token = "NextToken", output_token = "NextToken", items = "Items" }
    local all = {}
    for item in paginator.items(client, "listThings", {}, config) do
        all[#all + 1] = item
    end
    assert_eq(#all, 1, "skips empty page")
    assert_eq(all[1], "a", "gets item from second page")
end

-- Test: pages() with nested output token
print("--- pages: nested output token ---")
do
    local captured_inputs = {}
    local call_count = 0
    local client = {
        listThings = function(self, input)
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
    assert_eq(call_count, 2, "two calls with nested token")
    assert_eq(captured_inputs[2].Cursor, "abc", "nested token extracted and injected")
end

-- Summary
print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
