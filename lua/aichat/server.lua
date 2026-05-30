-- aichat.nvim 本地能力服务端 (Local Capability Server)
-- 仅暴露「前端」能力给子代理 (pi) 调用：展示相关文件、受限编辑当前可见文件。
-- 所有编辑器逻辑/校验/UI 都集中在本层；pi 扩展只是瘦桥接转发到这里。
local M = {}

-- 延迟引用 window，避免循环依赖
local function win()
  return require("aichat.window")
end

-- 把相对路径解析为绝对路径
local function to_abs(path)
  return vim.fn.fnamemodify(path, ":p")
end

-- 查找当前所有「普通(非浮窗)可见窗口」中正在显示该文件的窗口
-- 返回 win_id, buf_id；找不到返回 nil
local function find_visible_window_for(abs_path)
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(w) then
      local cfg = vim.api.nvim_win_get_config(w)
      -- relative == "" 表示普通窗口（排除浮窗，如本插件的聊天窗）
      if cfg.relative == "" then
        local b = vim.api.nvim_win_get_buf(w)
        local bname = vim.api.nvim_buf_get_name(b)
        if bname ~= "" and to_abs(bname) == abs_path then
          return w, b
        end
      end
    end
  end
  return nil, nil
end

-- 查找一个适合用来「打开新文件」的主窗口：普通(非浮窗)窗口，
-- 且不是本插件自身的列表/输入面板。优先返回当前窗口（若合适）。
local function find_main_window()
  local cur = vim.api.nvim_get_current_win()
  local function ok(w)
    if not vim.api.nvim_win_is_valid(w) then return false end
    if vim.api.nvim_win_get_config(w).relative ~= "" then return false end
    local b = vim.api.nvim_win_get_buf(w)
    local bt = vim.api.nvim_buf_get_option(b, "buftype")
    -- 排除 nofile/terminal 等非文件缓冲（本插件面板多为 nofile）
    if bt ~= "" then return false end
    return true
  end
  if ok(cur) then return cur end
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if ok(w) then return w end
  end
  return nil
end

-- ============================================================
-- 能力 1：展示与本次提问相关的文件（左侧扁平列表）
--   files: string[]  或  { {path=..., reason=...}, ... }
-- ============================================================
function M.present_files(files)
  if type(files) ~= "table" then
    return { status = "error", message = "files 参数必须是文件路径数组。" }
  end

  -- 归一化为 { path, reason } 列表（reason 即该文件的功能介绍）
  local norm = {}
  for _, item in ipairs(files) do
    if type(item) == "string" then
      table.insert(norm, { path = item })
    elseif type(item) == "table" and item.path then
      table.insert(norm, { path = item.path, reason = item.description or item.reason })
    end
  end

  if #norm == 0 then
    return { status = "error", message = "未提供任何有效文件路径。" }
  end

  -- 调度到主循环渲染前端面板（RPC 回调可能不在主线程上下文）
  vim.schedule(function()
    win().open_file_list(norm)
  end)

  return { status = "success", count = #norm, message = "已在左侧列表展示 " .. #norm .. " 个相关文件。" }
end

-- ============================================================
-- 能力 2：受限编辑——只允许修改「当前可见窗口里显示的文件」
--   path: 目标文件；search/replace: 精确查找替换（明文，不走正则）
-- ============================================================
function M.edit_file(path, search, replace)
  if type(path) ~= "string" or path == "" then
    return { status = "error", message = "path 不能为空。" }
  end
  if type(search) ~= "string" or search == "" then
    return { status = "error", message = "search 不能为空。" }
  end
  replace = replace or ""

  local abs = to_abs(path)

  -- 校验：必须是当前某个普通可见窗口正在显示的文件（用户正在看的文件）
  local _, buf = find_visible_window_for(abs)
  if not buf then
    return {
      status = "error",
      message = "拒绝修改：目标文件未显示在任何可见窗口中，只能修改用户当前正在查看的文件。",
      path = path,
    }
  end

  -- 在活 buffer 上做明文精确查找替换（保留撤销历史，不丢未保存改动）
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local content = table.concat(lines, "\n")
  local s, e = content:find(search, 1, true)
  if not s then
    return {
      status = "error",
      message = "在目标文件中未精确匹配到 search 文本，请提供一字不差的待替换片段。",
      path = path,
    }
  end

  -- 检测是否多处匹配（避免误改）
  local s2 = content:find(search, e + 1, true)
  if s2 then
    return {
      status = "error",
      message = "search 文本在文件中出现多处，无法确定唯一替换位置，请提供更长、唯一的片段。",
      path = path,
    }
  end

  local new_content = content:sub(1, s - 1) .. replace .. content:sub(e + 1)
  local new_lines = vim.split(new_content, "\n")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)

  return {
    status = "success",
    path = path,
    message = "已在当前可见文件中完成精确替换（改动可用 u 撤销，请自行保存）。",
  }
end

-- ============================================================
-- 能力 3：在右上角按需展示一张流程图（markdown / mermaid）
--   content: markdown 文本；title: 可选标题
-- ============================================================
function M.present_diagram(content, title)
  if type(content) ~= "string" or content == "" then
    return { status = "error", message = "content 不能为空。" }
  end
  vim.schedule(function()
    win().show_diagram(content, title)
  end)
  return { status = "success", message = "已在右上角展示流程图。" }
end

-- ============================================================
-- 能力 4：在右上角展示一段精简文本说明（≤300 字）。
--   content: 说明文本（服务端会硬性截断到 300 字以内）
-- ============================================================
function M.present_text(content)
  if type(content) ~= "string" or content == "" then
    return { status = "error", message = "content 不能为空。" }
  end
  -- 硬性截断到 300 字（按字符计），避免文本框过长
  if vim.fn.strchars(content) > 300 then
    content = vim.fn.strcharpart(content, 0, 300) .. "…"
  end
  vim.schedule(function()
    win().show_text(content)
  end)
  return { status = "success", message = "已在右上角展示说明。" }
end

-- ============================================================
-- 能力 5：把光标跳转到某个文件的指定行并居中（翻页定位）。
--   path: 目标文件；line: 目标行(1 基)；col: 可选列(1 基)
--   优先跳到已可见窗口；若文件未显示，则在主窗口中打开它。
--   跳转后强制进入普通(命令)模式，便于继续用键盘浏览。
-- ============================================================
function M.goto_location(path, line, col)
  if type(path) ~= "string" or path == "" then
    return { status = "error", message = "path 不能为空。" }
  end
  line = tonumber(line)
  if not line or line < 1 then
    return { status = "error", message = "line 必须为正整数。" }
  end
  col = tonumber(col) or 1

  local abs = to_abs(path)
  local w, buf = find_visible_window_for(abs)
  local opened_new = false

  if not w then
    -- 文件未显示：在主窗口中打开它（允许跨文件跳转）
    if vim.fn.filereadable(abs) ~= 1 then
      return {
        status = "error",
        message = "目标文件在磁盘上不存在或不可读，无法打开：" .. path,
        path = path,
      }
    end
    local mw = find_main_window()
    if not mw then
      return {
        status = "error",
        message = "找不到可用于打开文件的主窗口，请改用 present_text 说明位置。",
        path = path,
      }
    end
    w = mw
    opened_new = true
  end

  vim.schedule(function()
    vim.cmd("stopinsert") -- 强制普通(命令)模式，而非插入模式
    pcall(vim.api.nvim_set_current_win, w)
    if opened_new then
      pcall(vim.api.nvim_win_call, w, function()
        vim.cmd("edit " .. vim.fn.fnameescape(abs))
      end)
    end
    local b = vim.api.nvim_win_get_buf(w)
    local last = vim.api.nvim_buf_line_count(b)
    local ln = line
    if ln > last then ln = last end
    pcall(vim.api.nvim_win_set_cursor, w, { ln, math.max(0, col - 1) })
    pcall(vim.api.nvim_win_call, w, function() vim.cmd("normal! zz") end)
  end)

  return {
    status = "success",
    path = path,
    line = line,
    opened_new = opened_new,
    message = opened_new
        and string.format("已在主窗口打开 %s 并跳转到第 %d 行（普通模式）。注意：这是跨文件跳转，请用 present_diagram 画出原文件与该文件的调用关系（标明跳转前/跳转后的文件）；若两者无关，请用 present_text 说明。", path, line)
        or string.format("已跳转到 %s 第 %d 行并居中显示（普通模式）。", path, line),
  }
end

-- ============================================================
-- 工具清单（供扩展发现/注册；也方便后续扩充能力只改 Lua）
-- ============================================================
function M.list_tools()
  return {
    {
      name = "present_files",
      description = "在编辑器左侧列表中展示与用户问题相关的文件（每个文件附一句话功能介绍），供用户直接打开。",
      parameters = {
        files = "{path, description}[]：相关文件及其功能介绍",
      },
    },
    {
      name = "present_diagram",
      description = "在右上角展示流程图。AI 只输出紧凑逻辑描述（每行 `A -> B`，可 `: 标签`，节点换行用 \\n），插件自动渲染为对齐 ASCII，禁止手画。",
      parameters = {
        content = "string：逻辑描述（非手画 ASCII），如 `开始 -> 校验 : 必填\\n校验 -> 完成`",
        title = "string：可选标题",
      },
    },
    {
      name = "present_text",
      description = "在右上角文本框展示精简说明（≤300 字）。必须分条罗列、每条一行、以「- 」或编号开头，保留换行；文字在上、流程图在下。",
      parameters = {
        content = "string：分条罗列的说明（每条一行，禁止无换行的一整段，超 300 字截断）",
      },
    },
    {
      name = "goto_location",
      description = "把光标跳转到某个文件的指定行并居中，并进入普通(命令)模式。可见文件直接跳；文件未显示则在主窗口打开它（允许跨文件跳转）。跨文件跳转后必须用 present_diagram 画出原文件与新文件的调用关系（标明跳转前/后的文件）；若两者无关则用 present_text 说明。",
      parameters = {
        path = "string：目标文件路径",
        line = "number：目标行号(1 基)",
        col = "number：可选列号(1 基)",
      },
    },
    {
      name = "edit_file",
      description = "修改用户当前正在查看(可见窗口)的某个文件的内容，使用精确查找替换。只能改可见文件，禁止跨文件/改未显示的文件。",
      parameters = {
        path = "string：目标文件路径（必须是当前可见窗口中显示的文件）",
        search = "string：待替换的原文片段（需在文件中唯一且一字不差）",
        replace = "string：替换后的新内容",
      },
    },
  }
end

-- 统一调度入口：扩展通过 RPC 调用 aichat.server.call(name, params)
function M.call(name, params)
  params = params or {}
  if name == "present_files" then
    return M.present_files(params.files)
  elseif name == "present_diagram" then
    return M.present_diagram(params.content, params.title)
  elseif name == "present_text" then
    return M.present_text(params.content)
  elseif name == "goto_location" then
    return M.goto_location(params.path, params.line, params.col)
  elseif name == "edit_file" then
    return M.edit_file(params.path, params.search, params.replace)
  else
    return { status = "error", message = "未知的工具: " .. tostring(name) }
  end
end

return M
