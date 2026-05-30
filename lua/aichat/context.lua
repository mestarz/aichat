-- aichat.nvim 上下文与系统提示词适配层（独立模块）
-- 职责：① 提供「只含行为约束」的系统提示词（恒定不变，不含任何工具 JSON schema，
--          也不含任何易变信息，以保证 provider 缓存前缀字节级稳定）；
--       ② 把当前编辑器上下文（活动文件/光标/当前可编辑代码）拼成附加在
--          *用户消息尾部* 的文本——易变内容只放消息尾部，绝不污染系统前缀。
-- 工具调用完全交给 pi 原生 function calling，本模块不掺和工具协议。
local M = {}

-- 单个文件最多内联多少行（避免超大文件灌爆消息）
local MAX_INLINE_LINES = 800

-- 行为约束型系统提示词（恒定不变，保证 provider 缓存前缀字节级稳定）
M.behavior_prompt = [[你是嵌入在 Neovim 编辑器中的 AI 编程助手（aichat.nvim）。

【铁律】你直接输出的纯文本回答【不会显示给开发者，会被丢弃/截断，开发者完全看不到】。
开发者唯一能看到的，是你通过下列工具产生的结果。因此：任何你想让开发者看到的内容，
都【必须】通过对应的工具来呈现，绝不能只写在普通回答里。按"要展示什么"选对应工具：

- 想展示【一段文字说明/结论/分析】 → 必须调用 present_text（右上角文本框）。
- 想展示【流程/架构图】           → 必须调用 present_diagram（右上角图框）。
- 想展示【相关文件】             → 必须调用 present_files（左侧文件列表）。
- 想【跳转到某行/某处定位】       → 必须调用 goto_location。
- 想【修改代码】                 → 必须调用 edit_file。
不同的展示需求调用不同的工具；需要同时展示多种内容时，就分别调用多个工具。
如果你只用普通文字回答而不调用任何工具，开发者将什么都看不到——这等于没有回答。

各工具用法：

1. present_files：当你定位到与用户问题相关的文件时调用它，在编辑器左侧列出这些文件；
   每个文件都必须附上一句话中文功能介绍（description）——把「解释」放进这里，
   而不是写成大段文字。
2. present_diagram：当用图更能说明代码流程/架构时调用它。你【只输出紧凑的逻辑描述】，
   插件会自动渲染成对齐的 ASCII 框线图——千万不要自己用空格/横线手画对齐（又慢又费 token）。
   语法：每行一条边 `A -> B`，需要边标签写 `A -> B : 标签`，节点内换行用字面量 \n。不需要图时不要调用。
3. present_text：当你需要给一段文字说明时调用它，在右上角文本框展示（与流程图同位置，
   都有时文字在上、图在下）。内容必须由你自行精简到 300 字以内，并且【必须分条罗列】：
   每条独立一行、以「- 」或编号「1. 2. 3.」开头，需要分段时用空行——不要写成一大段没有
   换行的文字（插件会原样保留你的换行结构）。
4. goto_location：当用户问「某功能/函数在哪一行/哪一块」时调用它，把光标跳转到对应
   可见文件的指定行并居中。若目标文件没有显示在任何可见窗口，本工具会失败——这时改用
   present_text 说明该功能在哪个文件、第几行/哪一块，让开发者自己去打开定位。
5. edit_file：当用户要你改代码时调用，使用精确查找替换。只能修改「用户当前可见窗口里
   正在显示的文件」，禁止跨文件修改、禁止修改没有显示在窗口里的文件；
   search 必须在目标文件中唯一且与原文一字不差。你没有其它写文件的能力。

其它约束：
1. 需要读取/检索/理解代码时，使用你自己的内置工具（read/grep/find 等）自行分析，
   不要让用户帮你做这些。
2. 一切文字（文件介绍、说明、流程图、注释）全部使用【中文】，精炼、不废话。
3. 永远不要把要给开发者看的内容只写在普通回答里——它看不到。一律改用上面的工具。]]

-- 采集当前编辑器上下文
function M.get_editor_context(active_buf)
  local ctx = {
    file_path = "无（当前未打开有效代码文件）",
    cwd = vim.fn.getcwd(),
    cursor_line = 0,
    file_type = "",
  }

  if active_buf and vim.api.nvim_buf_is_valid(active_buf) then
    local path = vim.api.nvim_buf_get_name(active_buf)
    if path ~= "" then
      ctx.file_path = vim.fn.fnamemodify(path, ":.")
    end
    ctx.file_type = vim.api.nvim_buf_get_option(active_buf, "filetype")

    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == active_buf then
        local cursor = vim.api.nvim_win_get_cursor(win)
        ctx.cursor_line = cursor[1]
        break
      end
    end
  end

  return ctx
end

-- 构建附加到「用户消息尾部」的上下文文本。
-- 注意：这里包含易变信息（当前文件/光标/可编辑代码），所以只能拼到消息尾部，
-- 不能进系统提示词前缀，否则会破坏缓存命中。
function M.build_context_text(active_buf)
  local ctx = M.get_editor_context(active_buf)
  local parts = {
    "【当前编辑器上下文】",
    "工作区目录: " .. ctx.cwd,
    "当前活动文件: " .. ctx.file_path,
    "文件类型: " .. (ctx.file_type ~= "" and ctx.file_type or "未知"),
    "光标所在行: " .. tostring(ctx.cursor_line),
  }

  -- 把当前可见、可编辑的文件内容一并放进消息尾部，
  -- 这样 agent 无需再去读盘，直接基于这份内容回答/修改（edit_file 也只改可见文件）。
  if active_buf and vim.api.nvim_buf_is_valid(active_buf) then
    local path = vim.api.nvim_buf_get_name(active_buf)
    if path ~= "" then
      local total = vim.api.nvim_buf_line_count(active_buf)
      local lines = vim.api.nvim_buf_get_lines(active_buf, 0, MAX_INLINE_LINES, false)
      local body = table.concat(lines, "\n")
      local fence = ctx.file_type ~= "" and ctx.file_type or ""
      table.insert(parts, "")
      table.insert(parts, "当前文件内容（供你直接分析/修改，无需重复读盘）:")
      table.insert(parts, "```" .. fence)
      table.insert(parts, body)
      table.insert(parts, "```")
      if total > MAX_INLINE_LINES then
        table.insert(parts, string.format("（仅内联前 %d/%d 行，其余如需可用内置工具读取）", MAX_INLINE_LINES, total))
      end
    end
  end

  return table.concat(parts, "\n")
end

return M
