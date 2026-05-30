-- aichat.nvim 核心入口文件 (支持全中文注释)
local M = {}
local config = require("aichat.config")
local window = require("aichat.window")
local ai = require("aichat.ai")

-- 插件初始化入口
function M.setup(opts)
  config.setup(opts)
end

-- 智能助手开关切换逻辑
function M.toggle()
  -- 如果悬浮窗口已经开启，则执行关闭
  if window.is_open() then
    window.close()
    return
  end

  -- 打开前，率先捕获当前活动的正常文本 Buffer，隔离临时/系统/AI 浮窗 Buffer
  local current_buf = vim.api.nvim_get_current_buf()
  local buf_type = vim.api.nvim_buf_get_option(current_buf, "buftype")
  
  if buf_type ~= "nofile" and buf_type ~= "prompt" then
    M.active_buf = current_buf
  end

  -- 打开悬浮交互界面
  window.open(M.active_buf)
end

-- 重置上下文对话历史
function M.reset_history()
  ai.reset_history()
  vim.notify("󰚩 [aichat.nvim] AI 智能助手会话历史已成功重置！", vim.log.levels.INFO)
end

return M
