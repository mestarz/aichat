-- aichat.nvim Pi-Agent 后端执行器 (无任何业务冗余，纯净执行端)
local M = {}
local config = require("aichat.config")

-- 衍生本地 Pi-Agent 进程并流式回传 stdout 原始文本
function M.run_pi_process(final_prompt, on_chunk, on_complete, on_error)
  local opts = config.get()
  local pi_bin = opts.pi_agent_path or "pi"
  local cmd = { pi_bin, final_prompt }

  local complete_response = ""
  
  local function on_stdout(err, chunk)
    if err then
      vim.schedule(function() on_error("Pi-Agent 数据读取错误: " .. tostring(err)) end)
      return
    end
    if not chunk or chunk == "" then return end

    complete_response = complete_response .. chunk
    vim.schedule(function() on_chunk(chunk) end)
  end

  local function on_exit(obj)
    if obj.code ~= 0 then
      vim.schedule(function()
        on_error("Pi-Agent 运行异常退出，错误码: " .. obj.code .. "。请检查是否安装了 pi 命令行代理工具。")
      end)
      return
    end

    vim.schedule(function()
      on_complete(complete_response)
    end)
  end

  -- 使用 Neovim 异步进程系统拉起 Pi-Agent 终端代理
  vim.system(cmd, { stdout = on_stdout }, on_exit)
end

return M
