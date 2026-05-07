

local M = {}






local function run_read(interceptors, hook_name, context)
   local last_err
   for i = 1, #interceptors do
      local ic = interceptors[i]
      local hook = ic[hook_name]
      if hook then
         local ok, err = pcall(hook, interceptors[i], context)
         if not ok then
            last_err = err
         end
      end
   end
   return last_err
end

local function run_modify(interceptors, hook_name, context, field_name)
   local value = context[field_name]
   for i = 1, #interceptors do
      local ic = interceptors[i]
      local hook = ic[hook_name]
      if hook then
         local ok, result = pcall(hook, interceptors[i], context)
         if not ok then
            return nil, result
         end
         if result ~= nil then
            value = result
            context[field_name] = value
         end
      end
   end
   return value, nil
end

local function run_modify_completion(interceptors, hook_name, context, current_err)
   local output = context.output
   local err = current_err
   for i = 1, #interceptors do
      local ic = interceptors[i]
      local hook = ic[hook_name]
      if hook then
         local ok, new_output, new_err = pcall(hook, interceptors[i], context, err)
         if not ok then
            err = new_output
            output = nil
         else
            output = new_output
            err = new_err
            context.output = output
         end
      end
   end
   return output, err
end

local function run_read_with_error(interceptors, hook_name, context, current_err)
   local err = current_err
   for i = 1, #interceptors do
      local ic = interceptors[i]
      local hook = ic[hook_name]
      if hook then
         local ok, new_err = pcall(hook, interceptors[i], context, err)
         if not ok then
            err = new_err
         end
      end
   end
   return err
end

M.run_read = run_read
M.run_modify = run_modify
M.run_modify_completion = run_modify_completion
M.run_read_with_error = run_read_with_error

return M
