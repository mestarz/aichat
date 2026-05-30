-- aichat.nvim 窗口管理器（全中文交互）
-- 设计：
--   ① 顶部「提问输入框」：提交即关，想再问用空格空格重新唤起；
--   ② 左侧「相关文件」真实分割窗（present_files）：每个文件带功能介绍，
--      j/k 按「文件」跳转、跳过解释行，可用 <C-w> 原生切换；
--   ③ 右上角「流程图」浮窗：仅当 AI 调用 present_diagram 时按需出现（AI 直接画 ASCII 字符画）；
--   ④ 轻量「处理中」指示。不再展示任何文字回答——AI 的结论/解释全部经工具落地。
local M = {}
local config = require("aichat.config")
local ai = require("aichat.ai")

-- 顶部输入框
M.input_buf = nil
M.input_win = nil

-- 右上角流程图窗（按需）
M.diagram_buf = nil
M.diagram_win = nil
M.diagram_title = nil

-- 右上角文本说明窗（按需）：与流程图同位置，二者都在则「文字在上、图在下」
M.text_buf = nil
M.text_win = nil

-- 轻量「处理中」状态浮窗
M.status_buf = nil
M.status_win = nil
M.status_timer = nil

-- 左侧相关文件面板
M.files_buf = nil
M.files_win = nil
M.files_data = {}          -- 行号 -> { path = ... }
M.files_header_lines = {}  -- 每个「文件名行」的行号，供 j/k 按文件跳转

M.active_buf = nil -- 呼出助手前用户的活动缓冲区
M.is_loading = false

-- 按显示宽度把一段文本逐字折行（中文无空格，按 display width 切分）
local function wrap_text(text, max_w)
  text = tostring(text or ""):gsub("%s*\n%s*", " ")
  local out, cur, cur_w = {}, "", 0
  local n = vim.fn.strchars(text)
  for i = 0, n - 1 do
    local ch = vim.fn.strcharpart(text, i, 1)
    local cw = vim.fn.strdisplaywidth(ch)
    if cur_w + cw > max_w and cur ~= "" then
      table.insert(out, cur)
      cur, cur_w = "", 0
    end
    cur = cur .. ch
    cur_w = cur_w + cw
  end
  if cur ~= "" then table.insert(out, cur) end
  return out
end

-- ============================================================
-- 左侧相关文件列表：像 nvim-tree/NERDTree 一样的「真实左侧分割窗口」，
-- 而非浮窗——这样可以用 Neovim 原生 <C-w>h/l 等快捷键在窗口间切换、移动。
--   items: { { path = "...", reason = "..." }, ... }
-- ============================================================
function M.open_file_list(items)
  local width = math.max(28, math.floor(vim.o.columns * 0.22))

  if not M.files_buf or not vim.api.nvim_buf_is_valid(M.files_buf) then
    M.files_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(M.files_buf, "buftype", "nofile")
    vim.api.nvim_buf_set_option(M.files_buf, "bufhidden", "hide")
    vim.api.nvim_buf_set_option(M.files_buf, "swapfile", false)
    vim.api.nvim_buf_set_option(M.files_buf, "filetype", "aichat-files")
  end

  -- 左侧竖直分割（普通窗口，可被 <C-w> 等原生命令切换/移动）。
  -- 不抢占焦点：用户仍停留在原窗口，需要时自行 <C-w>h 进入文件列表。
  if not (M.files_win and vim.api.nvim_win_is_valid(M.files_win)) then
    local cur = vim.api.nvim_get_current_win()
    vim.cmd("noautocmd topleft vertical " .. width .. " split")
    M.files_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(M.files_win, M.files_buf)
    vim.api.nvim_win_set_option(M.files_win, "number", false)
    vim.api.nvim_win_set_option(M.files_win, "relativenumber", false)
    vim.api.nvim_win_set_option(M.files_win, "signcolumn", "no")
    vim.api.nvim_win_set_option(M.files_win, "winfixwidth", true)
    vim.api.nvim_win_set_option(M.files_win, "wrap", false)
    vim.api.nvim_win_set_option(M.files_win, "cursorline", true)
    if vim.api.nvim_win_is_valid(cur) then
      vim.api.nvim_set_current_win(cur)
    end
  else
    vim.api.nvim_win_set_width(M.files_win, width)
  end

  local content = { "  󰈚  相关文件 (Enter 打开，q 关闭)", "  ────────────────────────", "" }
  M.files_data = {}
  M.files_header_lines = {}

  if not items or #items == 0 then
    table.insert(content, "  ❌ 暂无相关文件。")
  else
    -- 解释行可用宽度：面板宽度减去前缀缩进与边距
    local desc_w = math.max(8, width - 8)
    for i, item in ipairs(items) do
      table.insert(content, string.format("  [%d] 󰈚  %s", i, item.path))
      M.files_data[#content] = { path = item.path }
      table.insert(M.files_header_lines, #content)
      if item.reason and item.reason ~= "" then
        -- 功能介绍：按宽度折成多行显示在文件名下方，每行都映射回同一文件，
        -- 但都不计入 header_lines，j/k 不会停在这些行上。
        local wrapped = wrap_text(item.reason, desc_w)
        for j, seg in ipairs(wrapped) do
          local prefix = (j == 1) and "    ↳ " or "      "
          table.insert(content, prefix .. seg)
          M.files_data[#content] = { path = item.path }
        end
      end
      table.insert(content, "")
    end
  end

  vim.api.nvim_buf_set_option(M.files_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(M.files_buf, 0, -1, false, content)
  vim.api.nvim_buf_set_option(M.files_buf, "modifiable", false)

  -- 初始光标落在第一个文件行
  if M.files_header_lines[1] then
    pcall(vim.api.nvim_win_set_cursor, M.files_win, { M.files_header_lines[1], 0 })
  end

  local map_opts = { buffer = M.files_buf, silent = true, noremap = true }

  -- j/k（含方向键）：在「文件」之间移动，跳过功能介绍行，每次只移动一个文件
  local function goto_file(delta)
    local hs = M.files_header_lines
    if #hs == 0 then return end
    local cur = vim.api.nvim_win_get_cursor(M.files_win)[1]
    local target
    if delta > 0 then
      for _, ln in ipairs(hs) do
        if ln > cur then target = ln break end
      end
      target = target or hs[#hs]
    else
      for i = #hs, 1, -1 do
        if hs[i] < cur then target = hs[i] break end
      end
      target = target or hs[1]
    end
    vim.api.nvim_win_set_cursor(M.files_win, { target, 0 })
  end
  vim.keymap.set("n", "j", function() goto_file(1) end, map_opts)
  vim.keymap.set("n", "k", function() goto_file(-1) end, map_opts)
  vim.keymap.set("n", "<Down>", function() goto_file(1) end, map_opts)
  vim.keymap.set("n", "<Up>", function() goto_file(-1) end, map_opts)

  -- 回车：在右侧的普通编辑窗口打开对应文件（排除文件列表窗与浮窗）
  vim.keymap.set("n", "<CR>", function()
    local cur = vim.api.nvim_win_get_cursor(M.files_win)[1]
    local target = M.files_data[cur]
    if not target then return end
    local main_win = nil
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(w)
        and w ~= M.files_win
        and vim.api.nvim_win_get_config(w).relative == "" then
        main_win = w
        break
      end
    end
    if main_win then
      vim.api.nvim_set_current_win(main_win)
      vim.cmd("edit " .. vim.fn.fnameescape(target.path))
    end
  end, map_opts)

  vim.keymap.set("n", "q", function() M.close_file_list() end, map_opts)
end

function M.close_file_list()
  if M.files_win and vim.api.nvim_win_is_valid(M.files_win) then
    vim.api.nvim_win_close(M.files_win, true)
  end
  M.files_win = nil
end

-- 初始化高亮组，贴合用户主题
local function setup_highlights()
  local hl_links = {
    AIChatHeader = "Title",
    AIChatTitle = "FloatTitle",
    AIChatPrompt = "Keyword",
  }
  for hl_name, link_to in pairs(hl_links) do
    vim.api.nvim_set_hl(0, hl_name, { link = link_to, default = true })
  end
end

-- ============================================================
-- 右上角「文本说明 + 流程图」共享区域。
--   两者同位置（右上角）；都存在时「文字在上、图在下」。
--   ① present_text  -> show_text  ：≤300 字的精简说明
--   ② present_diagram -> show_diagram：AI 直接绘制的 ASCII 字符画
-- ============================================================

-- 右上角区域的横向几何（宽度、列偏移）
local function topright_geom()
  local columns = vim.o.columns
  local width = math.max(40, math.floor(columns * 0.4))
  local col = math.max(2, columns - width - 2)
  return width, col
end

-- 文本说明窗当前应有的高度（依内容行数，3~16 行）
local function text_box_height()
  local n = (M.text_buf and vim.api.nvim_buf_is_valid(M.text_buf))
    and vim.api.nvim_buf_line_count(M.text_buf) or 3
  return math.max(3, math.min(n, 16))
end

local function text_win_opts()
  local width, col = topright_geom()
  return {
    relative = "editor",
    width = width,
    height = text_box_height(),
    row = 1,
    col = col,
    style = "minimal",
    border = "rounded",
    title = { { "  说明 (q 关闭) ", "AIChatHeader" } },
    title_pos = "center",
  }
end

local function diagram_win_opts()
  local width, col = topright_geom()
  local lines = vim.o.lines
  local row = 1
  -- 若文本框在上方，流程图整体下移（文本高度 + 上下边框各 1 行）
  if M.text_win and vim.api.nvim_win_is_valid(M.text_win) then
    row = 1 + text_box_height() + 2
  end
  local height = math.max(8, math.floor(lines * 0.4))
  local title = M.diagram_title and M.diagram_title ~= "" and M.diagram_title or "流程图"
  return {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = { { "  " .. title .. " (q 关闭) ", "AIChatHeader" } },
    title_pos = "center",
  }
end

-- 流程图存在时，按文本框是否存在重新定位它
local function reposition_diagram()
  if M.diagram_win and vim.api.nvim_win_is_valid(M.diagram_win) then
    vim.api.nvim_win_set_config(M.diagram_win, diagram_win_opts())
  end
end

-- 右上角「文本说明」浮窗：仅当 AI 调用 present_text 时按需出现。
--   content: 已精简的说明文本（服务端已截断到 300 字以内）
function M.show_text(content)
  local width = select(1, topright_geom())

  if not M.text_buf or not vim.api.nvim_buf_is_valid(M.text_buf) then
    M.text_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(M.text_buf, "buftype", "nofile")
    vim.api.nvim_buf_set_option(M.text_buf, "filetype", "text")
  end

  -- 保留 AI 的换行/分条结构：逐行处理，只对「超出宽度」的行再折行，
  -- 续行缩进 2 格以保持条目层次（避免压成一坨）。
  local max_w = math.max(8, width - 2)
  local body_lines = {}
  for _, raw in ipairs(vim.split(tostring(content or ""), "\n", { plain = true })) do
    local line = raw:gsub("%s+$", "")
    if line == "" then
      table.insert(body_lines, "")
    elseif vim.fn.strdisplaywidth(line) <= max_w then
      table.insert(body_lines, line)
    else
      local segs = wrap_text(line, max_w)
      for i, seg in ipairs(segs) do
        table.insert(body_lines, (i == 1) and seg or ("  " .. seg))
      end
    end
  end
  if #body_lines == 0 then body_lines = { "" } end
  vim.api.nvim_buf_set_option(M.text_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(M.text_buf, 0, -1, false, body_lines)
  vim.api.nvim_buf_set_option(M.text_buf, "modifiable", false)

  if M.text_win and vim.api.nvim_win_is_valid(M.text_win) then
    vim.api.nvim_win_set_config(M.text_win, text_win_opts())
  else
    M.text_win = vim.api.nvim_open_win(M.text_buf, false, text_win_opts())
    vim.api.nvim_win_set_option(M.text_win, "wrap", true)
  end

  -- 文本框高度可能变化 -> 重新定位下方的流程图
  reposition_diagram()

  vim.keymap.set("n", "q", function() M.close_text() end,
    { buffer = M.text_buf, silent = true, noremap = true })
end

function M.close_text()
  if M.text_win and vim.api.nvim_win_is_valid(M.text_win) then
    vim.api.nvim_win_close(M.text_win, true)
  end
  M.text_win = nil
  -- 文本框消失 -> 流程图回到顶部
  reposition_diagram()
end

-- 右上角「流程图」浮窗：仅当 AI 调用 present_diagram 时按需出现。
--   content: 纯 ASCII 字符画流程图（由 AI 直接绘制，无需任何外部渲染器）
function M.show_diagram(content, title)
  M.diagram_title = title

  if not M.diagram_buf or not vim.api.nvim_buf_is_valid(M.diagram_buf) then
    M.diagram_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(M.diagram_buf, "buftype", "nofile")
    vim.api.nvim_buf_set_option(M.diagram_buf, "filetype", "text")
  end

  local body = type(content) == "string" and content or ""
  -- 若内容是「逻辑描述」(含 -> 箭头)，本地确定性渲染成 ASCII；否则按原样显示。
  local render_lines
  local ok, flow = pcall(require, "aichat.flow")
  if ok and flow.looks_like_spec(body) then
    local rok, res = pcall(flow.render, body)
    render_lines = rok and res or vim.split(body, "\n", { plain = true })
  else
    render_lines = vim.split(body, "\n", { plain = true })
  end
  vim.api.nvim_buf_set_option(M.diagram_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(M.diagram_buf, 0, -1, false, render_lines)
  vim.api.nvim_buf_set_option(M.diagram_buf, "modifiable", false)

  if M.diagram_win and vim.api.nvim_win_is_valid(M.diagram_win) then
    vim.api.nvim_win_set_config(M.diagram_win, diagram_win_opts())
  else
    M.diagram_win = vim.api.nvim_open_win(M.diagram_buf, false, diagram_win_opts())
    vim.api.nvim_win_set_option(M.diagram_win, "wrap", false)
  end

  vim.keymap.set("n", "q", function() M.close_diagram() end,
    { buffer = M.diagram_buf, silent = true, noremap = true })
end

function M.close_diagram()
  if M.diagram_win and vim.api.nvim_win_is_valid(M.diagram_win) then
    vim.api.nvim_win_close(M.diagram_win, true)
  end
  M.diagram_win = nil
end

-- ============================================================
-- 轻量「处理中」指示：右上角一行小浮窗的旋转动画。
-- ============================================================
function M.start_spinner()
  M.is_loading = true
  local columns = vim.o.columns
  local width = 18

  if not M.status_buf or not vim.api.nvim_buf_is_valid(M.status_buf) then
    M.status_buf = vim.api.nvim_create_buf(false, true)
  end

  local opts = {
    relative = "editor",
    width = width,
    height = 1,
    row = 0,
    col = math.max(0, columns - width - 1),
    style = "minimal",
    focusable = false,
    zindex = 200,
  }
  if M.status_win and vim.api.nvim_win_is_valid(M.status_win) then
    vim.api.nvim_win_set_config(M.status_win, opts)
  else
    M.status_win = vim.api.nvim_open_win(M.status_buf, false, opts)
  end

  local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
  local idx = 1
  M.status_timer = vim.loop.new_timer()
  M.status_timer:start(0, 100, vim.schedule_wrap(function()
    if not M.is_loading or not M.status_win or not vim.api.nvim_win_is_valid(M.status_win) then
      if M.status_timer then
        M.status_timer:stop()
        M.status_timer:close()
        M.status_timer = nil
      end
      return
    end
    if M.status_buf and vim.api.nvim_buf_is_valid(M.status_buf) then
      vim.api.nvim_buf_set_lines(M.status_buf, 0, -1, false, { " " .. frames[idx] .. " AI 处理中…" })
    end
    idx = idx % #frames + 1
  end))
end

function M.stop_spinner()
  M.is_loading = false
  if M.status_timer then
    M.status_timer:stop()
    M.status_timer:close()
    M.status_timer = nil
  end
  if M.status_win and vim.api.nvim_win_is_valid(M.status_win) then
    vim.api.nvim_win_close(M.status_win, true)
  end
  M.status_win = nil
end

-- ============================================================
-- 生命周期
-- ============================================================
-- 关闭整个助手（输入框 + 文本框 + 流程图 + 状态 + 左侧文件列表）
function M.close()
  M.stop_spinner()
  M.close_input()
  M.close_text()
  M.close_diagram()
  M.close_file_list()
  M.is_loading = false
end

-- 只关闭顶部输入框（提交后调用：流程图/文件列表保留，输入框消失）
function M.close_input()
  if M.input_win and vim.api.nvim_win_is_valid(M.input_win) then
    vim.api.nvim_win_close(M.input_win, true)
  end
  M.input_win = nil
end

-- 是否处于「等待输入」状态：仅以输入框为准，
-- 这样即便流程图/文件列表还开着，再次空格空格也能重新唤起输入框。
function M.is_open()
  return M.input_win ~= nil and vim.api.nvim_win_is_valid(M.input_win)
end

-- 打开 AI 助手：只弹出顶部输入框
function M.open(active_buf)
  setup_highlights()
  M.active_buf = active_buf or vim.api.nvim_get_current_buf()

  local opts = config.get()
  local columns = vim.o.columns

  if not M.input_buf or not vim.api.nvim_buf_is_valid(M.input_buf) then
    M.input_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(M.input_buf, "filetype", "aichat-input")
  end

  local in_width = math.max(40, math.floor(columns * 0.5))
  local input_opts = {
    relative = "editor",
    width = in_width,
    height = opts.window.input.height,
    row = 1,
    col = 2,
    style = "minimal",
    border = opts.window.input.border,
    title = { { opts.window.input.title, "AIChatPrompt" } },
    title_pos = opts.window.input.title_pos,
  }
  M.input_win = vim.api.nvim_open_win(M.input_buf, true, input_opts)
  vim.api.nvim_buf_set_lines(M.input_buf, 0, -1, false, { "" })

  local map_opts = { buffer = M.input_buf, silent = true, noremap = true }
  vim.keymap.set({ "n", "i" }, "<Esc>", M.close, map_opts)
  vim.keymap.set({ "n", "i" }, "<C-c>", M.close, map_opts)
  vim.keymap.set("i", "<CR>", function() M.submit_prompt() end, map_opts)

  vim.cmd("startinsert")
end

-- 提交提问：发一次消息，pi 自身完成完整 agent 循环（分析→调工具→继续）。
-- 不展示任何文字回答；AI 的结论/解释全部通过 present_files / present_diagram /
-- edit_file 这些工具落地（由 pi 原生调用，经扩展回连 lua/aichat/server.lua 执行）。
function M.submit_prompt()
  if M.is_loading then return end

  local lines = vim.api.nvim_buf_get_lines(M.input_buf, 0, -1, false)
  local prompt = vim.trim(table.concat(lines, "\n"))
  if prompt == "" then return end

  vim.api.nvim_buf_set_lines(M.input_buf, 0, -1, false, { "" })

  -- 新一轮提问：清掉上一次的文本框与流程图
  M.close_text()
  M.close_diagram()
  -- 提交即关输入框（想再问就空格空格重新唤起）
  M.close_input()
  -- 轻量处理中指示
  M.start_spinner()

  ai.send_message(prompt, M.active_buf, {
    on_chunk = function(_chunk) end,            -- 不展示任何文字回答
    on_tool_start = function(_name, _args) end, -- 工具调用不在前端显示
    on_tool_end = function(_name, _result, _is_error) end,
    on_complete = function(_full_text)
      M.stop_spinner()
    end,
    on_error = function(err_msg)
      M.stop_spinner()
      vim.notify("aichat: " .. tostring(err_msg), vim.log.levels.ERROR)
    end,
  })
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
