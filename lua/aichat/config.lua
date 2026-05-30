-- aichat.nvim 默认配置文件
local M = {}

M.defaults = {
  provider = "deepseek", -- 默认 AI 服务商
  api_key = vim.env.DEEPSEEK_API_KEY or "", -- 自动读取环境变量
  model = "deepseek-v4-flash", -- 2026年4月最新发布的极速 MoE 架构推理模型
  base_url = "https://api.deepseek.com", -- DeepSeek 官方 API 终端
  temperature = 0.2, -- 低温度系数确保代码生成的严谨度与精确性
  max_tokens = 32768, -- 32K 最大 token，支持超大代码生成不被截断
  
  -- 缓存机制与上下文长度管理
  global_context_limit = 512000, -- 全局解析上下文上限限制为 512K tokens

  keymaps = {
    toggle = "<space><space>", -- 双击空格键触发/关闭 AI 助手
  },

  -- UI 样式配置与全中文标题设计
  window = {
    chat = {
      width = 0.55, -- 对话框占屏幕 55% 宽度
      height = 0.8, -- 占屏幕 80% 高度
      border = "rounded", -- 圆角边框，极具现代感
      title = " 󰚩  AI 智能编程助手 (aichat.nvim) ",
      title_pos = "center",
    },
    input = {
      height = 3, -- 3 行高度的提问输入框
      border = "rounded",
      title = " 提问输入框 (Esc 退出，Enter 发送) ",
      title_pos = "left",
    },
    results = {
      width = 0.35, -- 代码检索结果面板占屏幕 35% 宽度
      height = 0.8,
      border = "rounded",
      title = " 代码定位结果 (Enter 跳转，p 预览) ",
      title_pos = "center",
    }
  }
}

M.options = {}

-- 初始化配置合并
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})
  -- 若未显式传入 api_key，则尝试从标准环境变量中读取
  if M.options.api_key == "" then
    M.options.api_key = vim.env.DEEPSEEK_API_KEY or ""
  end
end

-- 获取当前生效配置
function M.get()
  return vim.tbl_isempty(M.options) and M.defaults or M.options
end

return M
