-- aichat.nvim 内置编辑器工具集
local M = {}

-- 检查文件是否存在的辅助函数
local function file_exists(path)
  local stat = vim.loop.fs_stat(path)
  return stat and stat.type == "file"
end

-- 如果是相对路径，根据当前项目工作区将其解析为绝对路径
local function resolve_path(path)
  if vim.fn.isdirectory(path) == 1 or file_exists(path) then
    return vim.fn.fnamemodify(path, ":p")
  end
  local workspace = vim.fn.getcwd()
  return vim.fn.fnamemodify(workspace .. "/" .. path, ":p")
end

-- 1. 查找项目文件 (find_files)
-- 语法匹配或文件名模糊查询
function M.find_files(pattern)
  pattern = pattern or ""
  -- 清理两侧的空格
  pattern = pattern:gsub("^%s+", ""):gsub("%s+$", "")
  
  -- 首选极其快速的 ripgrep 进行文件检索
  local cmd = { "rg", "--files" }
  local ok, res = pcall(vim.fn.systemlist, cmd)
  if not ok then
    -- 备选标准系统 find 命令
    ok, res = pcall(vim.fn.systemlist, { "find", ".", "-type", "f", "-not", "-path", "*/.*" })
  end
  
  if not ok or not res or #res == 0 then
    return { status = "error", message = "工作区中未找到任何文件，或检索工具运行出错。" }
  end

  local matches = {}
  local limit = 20 -- 最多返回 20 个相近匹配
  for _, file in ipairs(res) do
    -- 清理路径中的前置 ./ 符号
    local clean_file = file:gsub("^%./", "")
    if pattern == "" or clean_file:lower():find(pattern:lower(), 1, true) then
      table.insert(matches, clean_file)
      if #matches >= limit then break end
    end
  end

  return { status = "success", results = matches }
end

-- 2. 全局代码文本检索 (grep_search)
-- 基于 ripgrep 寻找特定关键字的代码行
function M.grep_search(query)
  if not query or query == "" then
    return { status = "error", message = "检索关键字不能为空。" }
  end

  -- 使用 ripgrep 并以 vimgrep 格式返回，便于行号和偏置提取
  local cmd = { "rg", "--vimgrep", "--smart-case", "--", query }
  local ok, res = pcall(vim.fn.systemlist, cmd)
  if not ok then
    -- 备选系统标准 grep
    cmd = { "grep", "-rnI", "--exclude-dir=.*", query, "." }
    ok, res = pcall(vim.fn.systemlist, cmd)
  end

  if not ok or not res or #res == 0 then
    return { status = "success", results = {}, message = "未匹配到任何包含该字样的代码。" }
  end

  local results = {}
  local limit = 30 -- 最多展现 30 条匹配，防止窗口文字膨胀
  for _, line in ipairs(res) do
    local parts = vim.split(line, ":")
    if #parts >= 3 then
      local filename = parts[1]:gsub("^%./", "")
      local lnum = tonumber(parts[2])
      local text = ""
      if #parts >= 4 and tonumber(parts[3]) ~= nil then
        text = table.concat(parts, ":", 4)
      else
        text = table.concat(parts, ":", 3)
      end
      
      table.insert(results, {
        file = filename,
        line = lnum,
        text = text:gsub("^%s+", "")
      })
      if #results >= limit then break end
    end
  end

  return { status = "success", results = results }
end

-- 3. 读取特定文件内容 (read_file)
-- 帮助 AI 在进行精细化修改前对代码文件进行完整/局部审查
function M.read_file(path, start_line, end_line)
  if not path or path == "" then
    return { status = "error", message = "读取文件路径不能为空。" }
  end

  local abs_path = resolve_path(path)
  if not file_exists(abs_path) then
    return { status = "error", message = "文件不存在: " .. path }
  end

  start_line = tonumber(start_line) or 1
  end_line = tonumber(end_line) or 300 -- 默认限制 300 行

  local lines = vim.fn.readfile(abs_path)
  local file_length = #lines
  if start_line > file_length then
    return { status = "error", message = "起始行号已超过文件总行数 (" .. file_length .. "行)。" }
  end

  local results = {}
  local actual_end = math.min(end_line, file_length)
  for i = start_line, actual_end do
    table.insert(results, lines[i])
  end

  return {
    status = "success",
    file = path,
    start_line = start_line,
    end_line = actual_end,
    total_lines = file_length,
    content = table.concat(results, "\n")
  }
end

-- 4. 局部缓冲区替换修改 (edit_buffer)
-- 帮助 AI 对现有代码块进行极其精准的“查找与替换”修改
function M.edit_buffer(path, search, replace)
  if not path or path == "" then
    return { status = "error", message = "文件路径不能为空。" }
  end
  if not search or search == "" then
    return { status = "error", message = "查找目标内容不能为空。" }
  end
  replace = replace or ""

  local abs_path = resolve_path(path)
  local buf = vim.fn.bufadd(abs_path)
  vim.fn.bufload(buf)

  -- 获取缓冲区当前所有的内容
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local content = table.concat(lines, "\n")

  -- 采取明文精确查找（不转义正则，防大模型因特殊符号转义失败）
  local start_idx, end_idx = content:find(search, 1, true)
  if not start_idx then
    return {
      status = "error",
      message = "无法在目标文件中精确匹配到查找的文本块，请提供一字不差的待替换代码段。"
    }
  end

  -- 执行替换并写回 Buffer
  local new_content = content:sub(1, start_idx - 1) .. replace .. content:sub(end_idx + 1)
  local new_lines = vim.split(new_content, "\n")

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
  
  -- 静默保存，触发磁盘写入
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("silent! write")
  end)

  return {
    status = "success",
    file = path,
    message = "已成功完成查找替换，文件已更新保存。"
  }
end

-- 5. 光标处代码段写入 (insert_at_cursor)
-- 帮助 AI 直接在用户正在操作的代码行中瞬间生成/追加所需字段或代码
function M.insert_at_cursor(active_buf, content)
  if not active_buf or not vim.api.nvim_buf_is_valid(active_buf) then
    return { status = "error", message = "找不到有效的原活动编辑器上下文。" }
  end

  local lines = vim.split(content, "\n")
  
  -- 寻找正显示此 Buffer 的可见 Window
  local wins = vim.api.nvim_list_wins()
  local target_win = nil
  for _, win in ipairs(wins) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == active_buf then
      target_win = win
      break
    end
  end

  if target_win then
    local cursor = vim.api.nvim_win_get_cursor(target_win)
    local row = cursor[1] -- 1-indexed
    
    -- 在当前行下方写入新生成的内容
    vim.api.nvim_buf_set_lines(active_buf, row, row, false, lines)
    -- 并将光标自动偏移至新生成代码段的下方，方便继续输入
    pcall(vim.api.nvim_win_set_cursor, target_win, { row + #lines, 0 })
  else
    -- 后备方案：直接追加到文件最末尾
    local line_count = vim.api.nvim_buf_line_count(active_buf)
    vim.api.nvim_buf_set_lines(active_buf, line_count, line_count, false, lines)
  end

  -- 保存修改后的 Buffer
  vim.api.nvim_buf_call(active_buf, function()
    vim.cmd("silent! write")
  end)

  return { status = "success", message = "已成功在编辑器当前光标位置写入新代码。" }
end

return M
