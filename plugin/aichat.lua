-- aichat.nvim 自动命令与按键绑定模块
if vim.g.loaded_aichat then
  return
end
vim.g.loaded_aichat = 1

-- 注册 Neovim 全局指令，便于用户在命令行中手动唤起
vim.api.nvim_create_user_command("AIChatToggle", function()
  require("aichat").toggle()
end, {})

vim.api.nvim_create_user_command("AIChatReset", function()
  require("aichat").reset_history()
end, {})

-- 在 Neovim 启动并完全载入后，根据配置绑定快捷键
vim.schedule(function()
  local config = require("aichat.config")
  local opts = config.get()
  
  if opts.keymaps and opts.keymaps.toggle then
    vim.keymap.set("n", opts.keymaps.toggle, function()
      require("aichat").toggle()
    end, { desc = "双击空格唤起 AI 智能助手", silent = true })
  end
end)
