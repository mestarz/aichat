-- aichat.nvim 智能悬浮窗口管理器 (全中文交互界面)
local M = {}
local config = require("aichat.config")
local ai = require("aichat.ai")

-- 浮窗与缓冲区状态句柄
M.chat_buf = nil
M.chat_win = nil
M.input_buf = nil
M.input_win = nil
M.results_buf = nil
M.results_win = nil

M.active_buf = nil -- 记录呼出助手前用户的活动缓冲区
M.results_data = {} -- 映射检索面板的行号到具体的代码路径与行号
M.is_loading = false
M.spinner_timer = nil

-- 初始化美化高亮组，完美贴合用户当前的主题（如 Tokyonight, Catppuccin 等）
local function setup_highlights()
  local hl_links = {
    AIChatHeader = "Title",
    AIChatTitle = "FloatTitle",
    AIChatFile = "Directory",
    AIChatLine = "Number",
    AIChatComment = "Comment",
    AIChatBorder = "FloatBorder",
    AIChatSelected = "Visual",
    AIChatPrompt = "Keyword"
  }
  for hl_name, link_to in pairs(hl_links) do
    vim.api.nvim_set_hl(0, hl_name, { link = link_to, default = true })
  end
end

-- 关闭所有已开启的 AI 悬浮窗口，释放资源
function M.close()
  if M.spinner_timer then
    M.spinner_timer:stop()
    M.spinner_timer:close()
    M.spinner_timer = nil
  end

  if M.input_win and vim.api.nvim_win_is_valid(M.input_win) then
    vim.api.nvim_win_close(M.input_win, true)
  end
  if M.chat_win and vim.api.nvim_win_is_valid(M.chat_win) then
    vim.api.nvim_win_close(M.chat_win, true)
  end
  if M.results_win and vim.api.nvim_win_is_valid(M.results_win) then
    vim.api.nvim_win_close(M.results_win, true)
  end

  M.input_win = nil
  M.chat_win = nil
  M.results_win = nil
  M.is_loading = false
end

-- 判断助手视窗是否处于打开状态
function M.is_open()
  return (M.chat_win and vim.api.nvim_win_is_valid(M.chat_win)) or
         (M.input_win and vim.api.nvim_win_is_valid(M.input_win))
end

-- 在提问输入框中通过快捷键控制上方聊天视窗滚动
function M.scroll_chat(direction)
  if not M.chat_win or not vim.api.nvim_win_is_valid(M.chat_win) then return end
  local cmd = direction == "down" and [[\<C-d>]] or [[\<C-u>]]
  vim.api.nvim_win_call(M.chat_win, function()
    vim.cmd("normal! " .. vim.api.nvim_replace_termcodes(cmd, true, false, true))
  end)
end

-- 向聊天缓冲区追加渲染文本 (支持 markdown 渲染格式)
function M.append_to_chat(text)
  if not M.chat_buf or not vim.api.nvim_buf_is_valid(M.chat_buf) then return end
  
  local lines = vim.api.nvim_buf_get_lines(M.chat_buf, 0, -1, false)
  if #lines == 1 and lines[1] == "" then
    lines = {}
  end

  local new_lines = vim.split(text, "\n")
  
  if #lines > 0 then
    -- 合并新输入的第一行与上一行末尾，避免产生多余断行
    lines[#lines] = lines[#lines] .. new_lines[1]
    for i = 2, #new_lines do
      table.insert(lines, new_lines[i])
    end
  else
    lines = new_lines
  end

  vim.api.nvim_buf_set_option(M.chat_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(M.chat_buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(M.chat_buf, "modifiable", false)

  -- 自动滚动聚焦到最下方最新回答行
  if M.chat_win and vim.api.nvim_win_is_valid(M.chat_win) then
    local line_count = vim.api.nvim_buf_line_count(M.chat_buf)
    vim.api.nvim_win_set_cursor(M.chat_win, { line_count, 0 })
  end
end

-- 开启动态中文思考加载动画
function M.start_spinner()
  if not M.chat_win or not vim.api.nvim_win_is_valid(M.chat_win) then return end
  M.is_loading = true
  
  local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
  local idx = 1

  M.spinner_timer = vim.loop.new_timer()
  M.spinner_timer:start(0, 100, vim.schedule_wrap(function()
    if not M.is_loading or not M.chat_win or not vim.api.nvim_win_is_valid(M.chat_win) then
      if M.spinner_timer then
        M.spinner_timer:stop()
        M.spinner_timer:close()
        M.spinner_timer = nil
      end
      return
    end
    
    local spinner_title = " " .. frames[idx] .. " AI 助手正在思考中... "
    vim.api.nvim_win_set_config(M.chat_win, {
      title = { { spinner_title, "AIChatHeader" } }
    })
    
    idx = idx % #frames + 1
  end))
end

-- 停止思考动画，还原标题
function M.stop_spinner()
  M.is_loading = false
  if M.spinner_timer then
    M.spinner_timer:stop()
    M.spinner_timer:close()
    M.spinner_timer = nil
  end
  if M.chat_win and vim.api.nvim_win_is_valid(M.chat_win) then
    local opts = config.get()
    vim.api.nvim_win_set_config(M.chat_win, {
      title = { { opts.window.chat.title, "AIChatHeader" } }
    })
  end
end

-- 核心交互：侧边弹出代码检索结果定位面板 (并左移对话主窗体保持对称美)
function M.open_results(results)
  local opts = config.get()
  
  local columns = vim.o.columns
  local lines = vim.o.lines
  
  local chat_width = math.floor(columns * opts.window.chat.width)
  local results_width = math.floor(columns * opts.window.results.width)
  local chat_height = math.floor(lines * opts.window.chat.height - opts.window.input.height - 4)
  
  -- 计算横向排版，让对话框和侧边检索框完美并列居中
  local total_w = chat_width + results_width + 4
  local start_col = math.floor((columns - total_w) / 2)
  if start_col < 1 then start_col = 1 end

  -- 智能左移对话主窗体
  if M.chat_win and vim.api.nvim_win_is_valid(M.chat_win) then
    vim.api.nvim_win_set_config(M.chat_win, {
      relative = "editor",
      col = start_col,
      width = chat_width
    })
  end
  
  -- 智能左移提问输入框
  if M.input_win and vim.api.nvim_win_is_valid(M.input_win) then
    vim.api.nvim_win_set_config(M.input_win, {
      relative = "editor",
      col = start_col,
      width = chat_width
    })
  end

  -- 创建检索结果 Buffer
  if not M.results_buf or not vim.api.nvim_buf_is_valid(M.results_buf) then
    M.results_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(M.results_buf, "filetype", "aichat-results")
  end

  -- 在右侧并排开启检索浮窗
  local results_col = start_col + chat_width + 2
  local results_opts = {
    relative = "editor",
    width = results_width,
    height = chat_height + opts.window.input.height + 2,
    row = math.floor((lines - (chat_height + opts.window.input.height + 4)) / 2),
    col = results_col,
    style = "minimal",
    border = opts.window.results.border,
    title = { { opts.window.results.title, "AIChatTitle" } },
    title_pos = opts.window.results.title_pos,
  }

  if M.results_win and vim.api.nvim_win_is_valid(M.results_win) then
    vim.api.nvim_win_set_config(M.results_win, results_opts)
  else
    M.results_win = vim.api.nvim_open_win(M.results_buf, false, results_opts)
  end

  -- 全中文格式化检索条目
  local lines_content = {
    "  󰈚  【代码逻辑检索定位结果】",
    "  ────────────────────────────",
    ""
  }
  M.results_data = {} -- 清空原有跳转映射

  if not results or #results == 0 then
    table.insert(lines_content, "  ❌ 未找到任何符合条件的代码位置。")
  else
    for i, item in ipairs(results) do
      if type(item) == "string" then
        -- find_files 文件名匹配结果
        table.insert(lines_content, string.format("  [%d] 󰈚  %s", i, item))
        M.results_data[#lines_content] = { file = item, line = 1 }
        table.insert(lines_content, "")
      else
        -- grep_search 文本定位结果
        table.insert(lines_content, string.format("  [%d] 󰈚  %s", i, item.file))
        M.results_data[#lines_content] = { file = item.file, line = item.line }
        table.insert(lines_content, string.format("       第 %d 行: %s", item.line, item.text))
        M.results_data[#lines_content] = { file = item.file, line = item.line }
        table.insert(lines_content, "")
      end
    end
  end

  vim.api.nvim_buf_set_option(M.results_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(M.results_buf, 0, -1, false, lines_content)
  vim.api.nvim_buf_set_option(M.results_buf, "modifiable", false)

  -- 检索面板按键绑定
  local result_map_opts = { buffer = M.results_buf, silent = true, noremap = true }
  
  -- 回车键：关闭 AI 面板并直接跳转至对应文件及行号
  vim.keymap.set("n", "<CR>", function()
    local cursor_row = vim.api.nvim_win_get_cursor(M.results_win)[1]
    local target = M.results_data[cursor_row]
    if target then
      M.close()
      vim.cmd("edit " .. vim.fn.fnameescape(target.file))
      pcall(vim.api.nvim_win_set_cursor, 0, { target.line, 0 })
      vim.cmd("normal! zz") -- 居中对齐
      vim.notify("🎯 已跳转至文件: " .. target.file .. " 第 " .. target.line .. " 行", vim.log.levels.INFO)
    end
  end, result_map_opts)

  -- 'p' 键：在后台非浮窗主编辑器中直接预览跳转（AI 面板保持开启）
  vim.keymap.set("n", "p", function()
    local cursor_row = vim.api.nvim_win_get_cursor(M.results_win)[1]
    local target = M.results_data[cursor_row]
    if target and M.active_buf then
      local wins = vim.api.nvim_list_wins()
      local main_win = nil
      for _, win in ipairs(wins) do
        local cfg = vim.api.nvim_win_get_config(win)
        if cfg.relative == "" then
          main_win = win
          break
        end
      end

      if main_win then
        vim.api.nvim_win_call(main_win, function()
          vim.cmd("edit " .. vim.fn.fnameescape(target.file))
          pcall(vim.api.nvim_win_set_cursor, main_win, { target.line, 0 })
          vim.cmd("normal! zz")
        end)
      end
    end
  end, result_map_opts)

  -- 退出绑定
  vim.keymap.set("n", "q", M.close, result_map_opts)
  vim.keymap.set("n", "<Esc>", M.close, result_map_opts)
end

-- 打开 AI 智能助手主悬浮视窗
function M.open(active_buf)
  setup_highlights()
  M.active_buf = active_buf or vim.api.nvim_get_current_buf()

  local opts = config.get()
  local columns = vim.o.columns
  local lines = vim.o.lines

  local chat_width = math.floor(columns * opts.window.chat.width)
  local chat_height = math.floor(lines * opts.window.chat.height - opts.window.input.height - 4)
  
  local row = math.floor((lines - (chat_height + opts.window.input.height + 4)) / 2)
  local col = math.floor((columns - chat_width) / 2)

  -- 1. 创建对话主视窗
  if not M.chat_buf or not vim.api.nvim_buf_is_valid(M.chat_buf) then
    M.chat_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(M.chat_buf, "filetype", "markdown")
  end

  local chat_opts = {
    relative = "editor",
    width = chat_width,
    height = chat_height,
    row = row,
    col = col,
    style = "minimal",
    border = opts.window.chat.border,
    title = { { opts.window.chat.title, "AIChatHeader" } },
    title_pos = opts.window.chat.title_pos,
  }
  M.chat_win = vim.api.nvim_open_win(M.chat_buf, false, chat_opts)
  
  vim.api.nvim_win_set_option(M.chat_win, "wrap", true)
  vim.api.nvim_win_set_option(M.chat_win, "scrolloff", 2)

  -- 载入中文贴心使用指南
  local line_cnt = vim.api.nvim_buf_line_count(M.chat_buf)
  if line_cnt <= 1 and vim.api.nvim_buf_get_lines(M.chat_buf, 0, 1, false)[1] == "" then
    local ctx = ai.get_editor_context(M.active_buf)
    local greeting = "# 󰚩  欢迎使用 aichat.nvim 智能助手！\n"
                  .. "当前捕获的活动代码文件: `" .. ctx.file_path .. "`\n"
                  .. "────────────────────────────────────────────────────────────\n"
                  .. "你可以向我发送各种指令，我将全速为您效劳：\n"
                  .. "- **代码查找定位**：例如输入 *“帮我找一下 window 的打开逻辑在哪”*\n"
                  .. "- **在文件代码生成**：例如输入 *“在这个文件里帮我增加一个计算斐波那契的函数”*\n"
                  .. "- **上下文优化**：我们已深度优化 Prompt 缓存，首字响应几乎秒级渲染！\n"
                  .. "────────────────────────────────────────────────────────────\n\n"
    M.append_to_chat(greeting)
  end

  -- 2. 创建提问输入视窗
  if not M.input_buf or not vim.api.nvim_buf_is_valid(M.input_buf) then
    M.input_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(M.input_buf, "filetype", "aichat-input")
  end

  local input_opts = {
    relative = "editor",
    width = chat_width,
    height = opts.window.input.height,
    row = row + chat_height + 2,
    col = col,
    style = "minimal",
    border = opts.window.input.border,
    title = { { opts.window.input.title, "AIChatPrompt" } },
    title_pos = opts.window.input.title_pos,
  }
  M.input_win = vim.api.nvim_open_win(M.input_buf, true, input_opts)
  
  -- 输入框按键响应设定
  local map_opts = { buffer = M.input_buf, silent = true, noremap = true }
  
  vim.keymap.set({ "n", "i" }, "<Esc>", M.close, map_opts)
  vim.keymap.set({ "n", "i" }, "<C-c>", M.close, map_opts)

  -- 回车直接发送问题
  vim.keymap.set("i", "<CR>", function()
    M.submit_prompt()
  end, map_opts)

  -- 滚动视窗快捷控制
  vim.keymap.set({ "i", "n" }, "<C-d>", function() M.scroll_chat("down") end, map_opts)
  vim.keymap.set({ "i", "n" }, "<C-u>", function() M.scroll_chat("up") end, map_opts)

  -- Tab 键焦点切换
  vim.keymap.set("n", "<Tab>", function()
    if M.results_win and vim.api.nvim_win_is_valid(M.results_win) then
      vim.api.nvim_set_current_win(M.results_win)
    elseif M.chat_win and vim.api.nvim_win_is_valid(M.chat_win) then
      vim.api.nvim_set_current_win(M.chat_win)
    end
  end, map_opts)

  -- 默认自动唤起 insert 状态
  vim.cmd("startinsert")
end

-- 用户提交提问并唤起双通道分支 AI 回路
function M.submit_prompt()
  if M.is_loading then return end

  local lines = vim.api.nvim_buf_get_lines(M.input_buf, 0, -1, false)
  local prompt = table.concat(lines, "\n")
  prompt = vim.trim(prompt)

  if prompt == "" then return end

  -- 清理提问框
  vim.api.nvim_buf_set_lines(M.input_buf, 0, -1, false, { "" })

  -- 向主面板追加渲染当前问题
  M.append_to_chat("👤 **您**:\n" .. prompt .. "\n\n")
  
  -- 判断是否即将切换分支用于代码生成
  local is_gen = ai.is_code_generation_task(prompt)
  if is_gen then
    M.append_to_chat("󰚩 **AI 助手 (已切出代码生成分支，极速处理中...)**:\n")
  else
    M.append_to_chat("󰚩 **AI 智能助手 (全局解析中...)**:\n")
  end

  -- 开启思考动画
  M.start_spinner()

  -- 双上下文分支的多轮迭代闭环
  local function run_chat_loop(current_prompt)
    ai.send_message(
      current_prompt,
      M.active_buf,
      -- on_chunk
      function(chunk)
        M.append_to_chat(chunk)
      end,
      -- on_complete
      function(full_text, tool_run)
        M.stop_spinner()
        M.append_to_chat("\n\n")

        if tool_run then
          local result = tool_run.result
          
          -- 根据执行的不同工具呈现全中文的执行反馈
          if tool_run.tool == "find_files" or tool_run.tool == "grep_search" then
            M.append_to_chat("🛠️ *[执行全局定位: " .. tool_run.tool .. "]*\n")
            if result.status == "success" then
              M.open_results(result.results)
              M.append_to_chat("🔍 *成功定位到 " .. #result.results .. " 处代码，已呈现在右侧定位面板中。*\n\n")
            else
              M.append_to_chat("❌ *定位执行失败: " .. result.message .. "*\n\n")
            end
          elseif tool_run.tool == "edit_buffer" or tool_run.tool == "insert_at_cursor" then
            M.append_to_chat("🛠️ *[执行分支写入: " .. tool_run.tool .. "]*\n")
            if result.status == "success" then
              M.append_to_chat("✅ *代码段已成功写入 Neovim 活跃文件并保存！*\n\n")
            else
              M.append_to_chat("❌ *代码段写入失败: " .. result.message .. "*\n\n")
            end
          elseif tool_run.tool == "read_file" then
            M.append_to_chat("🛠️ *[执行代码审查: 审查文件内容]*\n")
            if result.status == "success" then
              M.append_to_chat("📖 *成功读取 " .. result.file .. " 自 " .. result.start_line .. " 至 " .. result.end_line .. " 行内容。*\n\n")
            else
              M.append_to_chat("❌ *读取审查失败: " .. result.message .. "*\n\n")
            end
          end

          -- 自动发起下一轮反馈，把执行状态递加在会话尾部，保证 prompt 缓存不失效
          M.start_spinner()
          local feedback_prompt = "工具调用执行反馈 (" .. tool_run.tool .. "):\n" .. vim.json.encode(result)
          M.append_to_chat("󰚩 **AI 助手** (正在进行分析与确认):\n")
          run_chat_loop(feedback_prompt)
        else
          -- 本轮流式交互彻底结束，还原输入焦点
          if M.input_win and vim.api.nvim_win_is_valid(M.input_win) then
            vim.api.nvim_set_current_win(M.input_win)
            vim.cmd("startinsert")
          end
        end
      end,
      -- on_error
      function(err_msg)
        M.stop_spinner()
        M.append_to_chat("\n❌ **发生错误**: " .. err_msg .. "\n\n")
      end
    )
  end

  -- 开启对话轮次！
  run_chat_loop(prompt)
end

-- 快捷命令开关切换
function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

return M
