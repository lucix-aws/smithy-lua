

local M = { PaginatorConfig = {} }












local function get_path(obj, path)
   local val = obj
   for seg in path:gmatch("[^.]+") do
      if type(val) ~= "table" then return nil end
      val = (val)[seg]
   end
   return val
end

local function shallow_copy(t)
   local out = {}
   for k, v in pairs(t) do out[k] = v end
   return out
end

function M.pages(client, op_name, input, config)
   local done = false
   local prev_token = nil

   return function()
      if done then return nil end

      local cl = client
      local op_fn = cl[op_name]
      local output, err = op_fn(client, input)
      if err then
         done = true
         return nil, err
      end

      local next_token = get_path(output, config.output_token)

      if next_token == nil or next_token == "" or next_token == prev_token then
         done = true
      else
         prev_token = next_token
         input = shallow_copy(input)
         input[config.input_token] = next_token
      end

      return output, nil
   end
end

function M.items(client, op_name, input, config)
   if not config.items then
      error("paginator.items() requires config.items to be set")
   end

   local page_iter = M.pages(client, op_name, input, config)
   local current_items = nil
   local idx = 0

   return function()
      while true do
         if current_items and idx < #current_items then
            idx = idx + 1
            return current_items[idx]
         end

         local output, err = page_iter()
         if output == nil then
            if err then
               local e = err
               error((e.message or e.code or "pagination error"))
            end
            return nil
         end

         current_items = get_path(output, config.items)
         idx = 0

         if type(current_items) ~= "table" then
            current_items = nil
         end
      end
   end
end

M._get_path = get_path

return M
