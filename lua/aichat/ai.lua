-- aichat.nvim 智能多后端路由网关 (实现直连端与 Pi-Agent 代理服务的解耦与动态路由)
local M = {}
local config = require("aichat.config")
local deepseek = require("aichat.backends.deepseek")
local pi_agent = require("aichat.backends.pi_agent")

-- 1. 共享辅助函数：获取当前编辑器的全中文上下文信息 (供 window.lua 与各后端使用)
function M.get_editor_context(active_buf)
  local ctx = {
    file_path = "无 (当前未打开任何有效代码文件)",
    cwd = vim.fn.getcwd(),
    cursor_line = 0,
    cursor_col = 0,
    file_type = "",
    buffer_lines = ""
  }

  if active_buf and vim.api.nvim_buf_is_valid(active_buf) then
    local path = vim.api.nvim_buf_get_name(active_buf)
    if path ~= "" then
      ctx.file_path = vim.fn.fnamemodify(path, ":.")
    end
    ctx.file_type = vim.api.nvim_buf_get_option(active_buf, "filetype")
    
    -- 寻找对应的 Window 获取光标位置
    local wins = vim.api.nvim_list_wins()
    for _, win in ipairs(wins) do
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == active_buf then
        local cursor = vim.api.nvim_win_get_cursor(win)
        ctx.cursor_line = cursor[1]
        ctx.cursor_col = cursor[2]
        break
      end
    end

    -- 智能获取光标上下邻近 75 行代码段，优化缓存命中
    local line_count = vim.api.nvim_buf_line_count(active_buf)
    local start_line = math.max(0, ctx.cursor_line - 75)
    local end_line = math.min(line_count, ctx.cursor_line + 75)
    local lines = vim.api.nvim_buf_get_lines(active_buf, start_line, end_line, false)
    ctx.buffer_lines = table.concat(lines, "\n")
  end

  return ctx
end

-- 2. 共享辅助函数：智能判定任务类型是“全局定位/分析”，还是“在当前活跃文件行内写入/修改代码”
function M.is_code_generation_task(prompt)
  local keywords = {
    "add", "insert", "create", "delete", "write", "modify", "change", "replace", "generate",
    "增添", "写入", "修改", "添加", "编写", "替换", "生成", "写一个", "插在", "加个"
  }
  local lower_prompt = prompt:lower()
  for _, word in ipairs(keywords) do
    if lower_prompt:find(word, 1, true) then
      return true
    end
  end
  return false
end

-- 3. 动态消息路由：将提问发送至所配置的后端进行处理
function M.send_message(user_prompt, active_buf, on_chunk, on_complete, on_error)
  local opts = config.get()
  
  if opts.backend == "pi-agent" then
    -- 路由至高级 Pi-Agent 代理客户端
    pi_agent.send_message(user_prompt, active_buf, on_chunk, on_complete, on_error)
  else
    -- 路由至内置的直连端 DeepSeek 极速 MoE 客户端
    deepseek.send_message(user_prompt, active_buf, on_chunk, on_complete, on_error)
  end
end

-- 4. 动态历史路由：一键重置所有后端的会话记忆
function M.reset_history()
  deepseek.reset_history()
  pi_agent.reset_history()
  vim.notify("󰚩 [aichat.nvim] AI 智能助手会话历史（包括直连与 Pi-Agent）已成功重置！", vim.log.levels.INFO)
end

return M
