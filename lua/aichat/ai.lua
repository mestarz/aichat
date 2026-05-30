-- aichat.nvim 智能 Pi-Agent 终端代理服务进程调度与核心状态编排管理器 (纯净无冗余中枢)
local M = {}
local config = require("aichat.config")
local tools = require("aichat.tools")

-- 1. 全局会话历史记录主存储 (Track A)
M.global_history = {}

-- 2. 重置会话历史记录
function M.reset_history()
  M.global_history = {}
  vim.notify("󰚩 [aichat.nvim] AI 智能助手会话历史已成功重置！", vim.log.levels.INFO)
end

-- 3. 全局 512K 历史剪裁逻辑 (Track A) —— 集中化状态管理
local function prune_global_history()
  local opts = config.get()
  local limit_chars = opts.global_context_limit * 4 -- 估算：1 token ≈ 4 字符

  local total_chars = 0
  for _, msg in ipairs(M.global_history) do
    total_chars = total_chars + #msg.content
  end

  -- 超限一刀斩断除首个摘要提示外的前半部分历史，瞬间腾出空间并保护缓存哈希
  if total_chars > limit_chars and #M.global_history > 2 then
    local total_items = #M.global_history
    local remaining_count = total_items - 1
    local to_remove = math.floor(remaining_count / 2)
    
    if to_remove > 0 then
      for _ = 1, to_remove do
        table.remove(M.global_history, 2)
      end
      
      vim.schedule(function()
        vim.notify("󰚩 [aichat.nvim] 全局解析上下文已超出 512K tokens 限制，已自动切除前半部旧会话以释放空间！", vim.log.levels.WARN)
      end)
    end
  end
end

-- 4. 集中化辅助函数：获取当前编辑器的全中文上下文信息 (供 window.lua 使用)
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

-- 5. 集中化辅助函数：智能判定任务类型是“全局定位/分析”，还是“在当前活跃文件行内写入/修改代码”
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

-- 6. 集中化静态提示词规范 (全中文 JSON schema 规范)
M.static_system_prompt = [[你是嵌入在极客开发环境 Neovim 编辑器中的 AI 智能编程助手 (aichat.nvim)。
你是一流的软件工程大师，需要用严谨、干练且直切要害的中文来解答用户提问。

核心规则：
1. 你的一切回复、代码注释以及工作报告，必须完全使用【中文】编写。
2. 每一个回答要逻辑清晰、字句精炼，严禁废话。
3. 当且仅当用户需要你执行文件检索、代码查找（Grep）等操作时，你才可以通过输出一个 Markdown 格式的 JSON 代码块来发起工具调用。
4. 调用工具时，你的回复中只能包含该 JSON 代码块本身，不得携带任何多余的寒暄与解释。

可供调用的全局分析工具：

1. 查找当前工作区下的文件：
```json
{
  "tool": "find_files",
  "arguments": {
    "pattern": "待匹配的文件名或后缀"
  }
}
```

2. 在当前工作区所有代码文件内容中全局检索特定关键字 (Grep)：
```json
{
  "tool": "grep_search",
  "arguments": {
    "query": "检索关键字"
  }
}
```

3. 读取某个具体文件的代码行段落：
```json
{
  "tool": "read_file",
  "arguments": {
    "path": "文件路径",
    "start_line": 1,
    "end_line": 150
  }
}
```
]]

M.branched_generation_prompt = [[你是 Neovim 下高阶代码编写分支器。
你必须且只能使用下面两个工具，直接在当前编辑的文件中增添字段或修改逻辑。

绝对指令：
1. 不要输出任何额外的闲聊解释！只输出你用于修改或插入代码的 JSON 代码块。
2. 对于 `edit_buffer`，确保 `search` 代码段与原文件内容一字不差地精准匹配。

可供调用的代码生成与写入工具：

1. 查找并替换文件中的指定代码段 (精确搜索替换)：
```json
{
  "tool": "edit_buffer",
  "arguments": {
    "path": "待修改的文件路径",
    "search": "待替换的完整代码原文",
    "replace": "替换后的全新代码内容"
  }
}
```

2. 直接在用户当前编辑器光标位置插入/追加新代码：
```json
{
  "tool": "insert_at_cursor",
  "arguments": {
    "content": "直接插入的全新代码块"
  }
}
```
]]

-- 7. 集中化工具分析拦截与执行逻辑
local function execute_tool_if_any(response_text, active_buf)
  local json_block = response_text:match("```json%s*(.-)%s*```")
  if not json_block then
    if response_text:sub(1, 1) == "{" and response_text:sub(-1, -1) == "}" then
      json_block = response_text
    end
  end

  if not json_block then return nil end

  local ok, decoded = pcall(vim.json.decode, json_block)
  if not ok or not decoded or not decoded.tool then return nil end

  local tool_name = decoded.tool
  local args = decoded.arguments or {}
  
  local result = nil
  if tool_name == "find_files" then
    result = tools.find_files(args.pattern)
  elseif tool_name == "grep_search" then
    result = tools.grep_search(args.query)
  elseif tool_name == "read_file" then
    result = tools.read_file(args.path, args.start_line, args.end_line)
  elseif tool_name == "edit_buffer" then
    result = tools.edit_buffer(args.path, args.search, args.replace)
  elseif tool_name == "insert_at_cursor" then
    result = tools.insert_at_cursor(active_buf, args.content)
  else
    result = { status = "error", message = "未知的工具名称: " .. tostring(tool_name) }
  end

  return {
    tool = tool_name,
    args = args,
    result = result
  }
end

-- 7. 异步拉起本地 Pi-Agent 进程并流式捕获 stdout
local function run_pi_process(final_prompt, on_chunk, on_complete_wrapper, on_error)
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
        on_error("Pi-Agent 运行异常退出，错误码: " .. obj.code .. "。请确认是否安装并正确配置了 pi 命令行代理工具。")
      end)
      return
    end

    vim.schedule(function()
      on_complete_wrapper(complete_response)
    end)
  end

  -- 使用 Neovim 异步进程系统拉起 Pi-Agent 终端代理
  vim.system(cmd, { stdout = on_stdout }, on_exit)
end

-- 8. 发送流式信息主入口 (多轨分支调度与 Neovim 专属工具逆向注入)
function M.send_message(user_prompt, active_buf, on_chunk, on_complete, on_error)
  local ctx = M.get_editor_context(active_buf)

  -- ==========================================
  -- 路线 A: 判定为局部代码编辑写入生成任务 -> 【切出临时分支会话】
  -- 杜绝冗余搜索日志污染，发挥最高 Prefill 速度与生成精准度，无损保存撤销历史与渲染
  -- ==========================================
  if M.is_code_generation_task(user_prompt) and active_buf then
    local branch_prompt = M.branched_generation_prompt .. "\n\n" .. string.format(
      "【Pi-Agent 代码生成分支指令】\n当前活动代码文件: %s\n行内代码邻近内容:\n```%s\n%s\n```\n光标所在行号: %d\n\n修改生成任务指令: %s\n\n"
      .. "【重要指示】：你正处于 Neovim 代码编辑中。请立刻调用 edit_buffer (精确搜索替换) 或 insert_at_cursor (光标行内写入) 工具，以标准的 ```json ... ``` 格式代码块输出。本分支请只输出 JSON 工具块本身，严禁任何废话解释！",
      ctx.file_path,
      ctx.file_type,
      ctx.buffer_lines,
      ctx.cursor_line,
      user_prompt
    )

    -- 封装响应解析回调
    run_pi_process(branch_prompt, on_chunk, function(full_response)
      local tool_run = execute_tool_if_any(full_response, active_buf)
      
      -- 生成最终的增量合并日志摘要
      local merge_summary = ""
      if tool_run then
        merge_summary = string.format(
          "🛠️ 【Pi-Agent 分支修改代码执行成功】\n执行工具: %s\n修改文件: %s\n执行结果: %s",
          tool_run.tool,
          ctx.file_path,
          tool_run.result.status == "success" and "成功" or "失败"
        )
      else
        merge_summary = string.format(
          "💬 【Pi-Agent 分支生成回复完成】\n回复摘要: %s",
          full_response:sub(1, 150) .. "..."
        )
      end

      -- 把这次分支变更同步回全局分析 Track A
      if #M.global_history == 0 then
        table.insert(M.global_history, { role = "system", content = "Pi-Agent 历史跟踪开始。" })
      end
      table.insert(M.global_history, { role = "user", content = user_prompt })
      table.insert(M.global_history, { role = "assistant", content = merge_summary })
      prune_global_history()

      on_complete(full_response, tool_run)
    end, on_error)

    return
  end

  -- ==========================================
  -- 路线 B: 全局解析 / 代码定位 Track A
  -- 维护 512K tokens 长会话前缀并进行增量修剪
  -- ==========================================
  if #M.global_history == 0 then
    -- 全局首轮自动获取项目结构 outlines 写入上下文，使 AI 拥有全景项目感知
    local files_res = tools.find_files("")
    local files_str = "未检索到任何文件"
    if files_res.status == "success" and #files_res.results > 0 then
      files_str = table.concat(files_res.results, ", ")
    end

    local init_summary = string.format(
      "【初始代码工作区概要】\n当前活动文件: %s\n工作区目录: %s\n整个项目已发现的代码文件清单: %s",
      ctx.file_path,
      ctx.cwd,
      files_str
    )
    table.insert(M.global_history, { role = "system", content = init_summary })
  end

  -- 追加提问并修剪
  table.insert(M.global_history, { role = "user", content = user_prompt })
  prune_global_history()

  -- 构建适合 Pi-Agent CLI 解析的长字符串上下文形式发送 (注入全局静态 system prompt 规范)
  local history_str = ""
  for _, item in ipairs(M.global_history) do
    history_str = history_str .. string.format("\n【%s】:\n%s\n", item.role == "user" and "用户提问" or "历史背景", item.content)
  end
  
  local final_global_prompt = M.static_system_prompt .. "\n\n" .. history_str .. "\n\n【最新提问指令】:\n" .. user_prompt
    .. "\n\n【重要指示】：如果你要检索定位代码，请使用 find_files 或 grep_search 工具。插件会自动在 Neovim 右侧弹出全中文的 [代码定位结果] 面板，支持回车跳转与 p 键预览！如果要读取代码，请使用 read_file 模块。在输出工具调用时，请严格输出标准的 ```json ... ``` 格式代码块，不得携带任何闲聊解释！"

  run_pi_process(final_global_prompt, on_chunk, function(full_response)
    table.insert(M.global_history, { role = "assistant", content = full_response })
    prune_global_history()

    local tool_run = execute_tool_if_any(full_response, active_buf)
    if tool_run then
      -- 执行了定位工具，将结果做成 user 增量反馈，发起多轮循环
      local feedback_str = string.format(
        "【Pi-Agent 全局定位工具执行结果】\n工具: %s\n执行状态: %s\n返回数据: \n%s",
        tool_run.tool,
        tool_run.result.status,
        vim.json.encode(tool_run.result)
      )
      table.insert(M.global_history, { role = "user", content = feedback_str })
      prune_global_history()
    end

    on_complete(full_response, tool_run)
  end, on_error)
end

return M
