

local http_mod = require("smithy.http")

local interceptor_mod = { Context = {} }











function interceptor_mod.run_read(interceptors, hook_name, context)
   local last_err = nil
   for i = 1, #interceptors do
      local hook = (interceptors[i])[hook_name]
      if hook then
         local ok, err_val = pcall(hook, interceptors[i], context)
         if not ok then
            last_err = err_val
         end
      end
   end
   return last_err
end

function interceptor_mod.run_modify(interceptors, hook_name, context, field)
   local value = (context)[field]
   for i = 1, #interceptors do
      local hook = (interceptors[i])[hook_name]
      if hook then
         local ok, result = pcall(hook, interceptors[i], context)
         if not ok then
            return nil, result
         end
         if result ~= nil then
            value = result;
            (context)[field] = value
         end
      end
   end
   return value, nil
end

function interceptor_mod.run_modify_completion(interceptors, hook_name, context, current_err)
   local output = context.output
   local err = current_err
   for i = 1, #interceptors do
      local hook = (interceptors[i])[hook_name]
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

function interceptor_mod.run_read_with_error(interceptors, hook_name, context, current_err)
   local err = current_err
   for i = 1, #interceptors do
      local hook = (interceptors[i])[hook_name]
      if hook then
         local ok, new_err_val = pcall(hook, interceptors[i], context, err)
         if not ok then
            err = new_err_val
         end
      end
   end
   return err
end

return interceptor_mod
