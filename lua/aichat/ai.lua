-- aichat.nvim 智能大模型管理器 (支持双上下文分支架构与输入缓存优化)
local M = {}
local config = require("aichat.config")
local tools = require("aichat.tools")

-- 全局解析上下文历史记录 (Track A)
M.global_history = {}

-- 重置上下文历史记录
function M.reset_history()
  M.global_history = {}
end

-- 全局上下文滚动修剪 (512K tokens 限制，约 2,048,000 字符。若超出，直接砍掉除第一条静态 System Prompt 外的前半部分会话历史)
local function prune_global_history()
  local opts = config.get()
  local limit_chars = opts.global_context_limit * 4 -- 估算：1 token ≈ 4 字符

  local total_chars = 0
  for _, msg in ipairs(M.global_history) do
    total_chars = total_chars + #msg.content
  end

  -- 当超出 512K tokens 限制时，保留第一条核心静态 System Prompt，直接将剩下历史会话的前一半全部斩断！
  if total_chars > limit_chars and #M.global_history > 2 then
    local total_items = #M.global_history
    local remaining_count = total_items - 1 -- 除首条 system 之外的条目数
    local to_remove = math.floor(remaining_count / 2)
    
    if to_remove > 0 then
      for _ = 1, to_remove do
        table.remove(M.global_history, 2) -- 持续删去索引 2 处的旧消息
      end
      
      -- 用中文通知用户，提示前半部分记忆已自动释放，保持极高缓存率
      vim.schedule(function()
        vim.notify("󰚩 [aichat.nvim] 全局解析上下文已超出 512K tokens 限制，已自动切除前半部旧会话以释放空间！", vim.log.levels.WARN)
      end)
    end
  end
end

-- 获取当前编辑器的中文上下文信息
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
    
    -- 寻找对应的 Window 获取光标
    local wins = vim.api.nvim_list_wins()
    for _, win in ipairs(wins) do
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == active_buf then
        local cursor = vim.api.nvim_win_get_cursor(win)
        ctx.cursor_line = cursor[1]
        ctx.cursor_col = cursor[2]
        break
      end
    end

    -- 智能获取光标上下 75 行代码片段，既能保证局部上下文完整，又极度精简以优化 Prompt 缓存
    local line_count = vim.api.nvim_buf_line_count(active_buf)
    local start_line = math.max(0, ctx.cursor_line - 75)
    local end_line = math.min(line_count, ctx.cursor_line + 75)
    local lines = vim.api.nvim_buf_get_lines(active_buf, start_line, end_line, false)
    ctx.buffer_lines = table.concat(lines, "\n")
  end

  return ctx
end

-- 静态系统提示词 (首字缓存优化，永久命中 DeepSeek Prompt Caching)
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

-- 静态代码生成分支提示词 (高度隔离，极致精准)
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

-- 智能判定任务类别：判断是全局分析定位(Grep/Find)，还是具体的在文件代码写入/生成(Insert/Edit)
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

-- 解析并执行 AI 响应中包含的 JSON 工具调用
function M.execute_tool_if_any(response_text, active_buf)
  -- 匹配 Markdown 格式的 ```json ... ``` 块
  local json_block = response_text:match("```json%s*(.-)%s*```")
  if not json_block then
    -- 后备匹配整个文本如果是 JSON 的情况
    if response_text:sub(1, 1) == "{" and response_text:sub(-1, -1) == "}" then
      json_block = response_text
    end
  end

  if not json_block then
    return nil
  end

  local ok, decoded = pcall(vim.json.decode, json_block)
  if not ok or not decoded or not decoded.tool then
    return nil
  end

  local tool_name = decoded.tool
  local args = decoded.arguments or {}
  
  -- 执行指定 Neovim 功能工具
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

-- 发送流式消息的总入口 (包含分支切换逻辑与全局 512K tokens 滚动修剪)
function M.send_message(user_prompt, active_buf, on_chunk, on_complete, on_error)
  local opts = config.get()
  
  if opts.api_key == "" then
    on_error("DeepSeek API 密钥未配置！请在环境变量中设置 DEEPSEEK_API_KEY，或在 setup 选项中传入。")
    return
  end

  -- 获取当前编辑器上下文
  local ctx = M.get_editor_context(active_buf)

  -- ==========================================
  -- 路线 A: 判定为在当前活跃文件进行局部“代码写入/修改/生成”
  -- 执行【切出分支】逻辑 (Branching)，构建极致精简的前缀进行精准生成与缓存匹配
  -- ==========================================
  if M.is_code_generation_task(user_prompt) and active_buf then
    local branch_history = {
      { role = "system", content = M.branched_generation_prompt },
      {
        role = "user",
        content = string.format(
          "【代码生成分支上下文】\n当前编辑文件: %s\n文件类型: %s\n光标所在行号: %d\n\n【文件邻近代码内容】:\n```%s\n%s\n```\n\n【生成任务说明】:\n%s",
          ctx.file_path,
          ctx.file_type,
          ctx.cursor_line,
          ctx.file_type,
          ctx.buffer_lines,
          user_prompt
        )
      }
    }

    -- 异步调用分支 payload
    M.call_api(branch_history, on_chunk, function(full_response, tool_run)
      -- 分支运行结束，把最终的中文摘要日志写入全局解析上下文 Track A
      local merge_summary = ""
      if tool_run then
        merge_summary = string.format(
          "🛠️ 【已切换代码生成分支成功修改代码】\n执行工具: %s\n文件: %s\n执行结果: %s",
          tool_run.tool,
          ctx.file_path,
          tool_run.result.status == "success" and "成功" or "失败"
        )
      else
        merge_summary = string.format(
          "💬 【切换代码生成分支并回复完成】\n回复摘要: %s",
          full_response:sub(1, 150) .. "..."
        )
      end

      -- 把这次分支变更同步给全局跟踪
      if #M.global_history == 0 then
        table.insert(M.global_history, { role = "system", content = M.static_system_prompt })
      end
      table.insert(M.global_history, { role = "user", content = user_prompt })
      table.insert(M.global_history, { role = "assistant", content = merge_summary })
      prune_global_history() -- 剪枝

      on_complete(full_response, tool_run)
    end, on_error)

    return
  end

  -- ==========================================
  -- 路线 B: 全局解析 / 代码逻辑定位 (Track A)
  -- 保持全局连续的 512k 缓存上下文
  -- ==========================================
  if #M.global_history == 0 then
    table.insert(M.global_history, { role = "system", content = M.static_system_prompt })
    
    -- 首次启动全局对话时，自动扫描获取工作区内的全部文件列表
    local files_res = tools.find_files("")
    local files_str = "未检索到任何文件"
    if files_res.status == "success" and #files_res.results > 0 then
      files_str = table.concat(files_res.results, ", ")
    end
    
    -- 第一轮追加活动文件概要与整个项目工作区的文件清单，使 AI 彻底具备全局文件结构感知！
    local workspace_context = string.format(
      "【初始代码工作区概要】\n当前活动文件: %s\n工作区目录: %s\n整个项目已发现的代码文件清单: %s",
      ctx.file_path,
      ctx.cwd,
      files_str
    )
    table.insert(M.global_history, { role = "system", content = workspace_context })
  end

  -- 追加用户的全局提问
  table.insert(M.global_history, { role = "user", content = user_prompt })
  prune_global_history() -- 保证不超过 512K Limit

  M.call_api(M.global_history, on_chunk, function(full_response, tool_run)
    table.insert(M.global_history, { role = "assistant", content = full_response })
    prune_global_history()

    if tool_run then
      -- 执行了定位工具，将结果转为 user 增量反馈，发起多轮循环
      local feedback_str = string.format(
        "【全局定位工具执行结果】\n工具: %s\n执行状态: %s\n返回数据: \n%s",
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

-- 封包执行网络调用与 SSE Streaming 文本提取
function M.call_api(messages_payload, on_chunk, on_complete_wrapper, on_error)
  local opts = config.get()
  local url = opts.base_url .. "/v1/chat/completions"

  local payload = {
    model = opts.model,
    messages = messages_payload,
    stream = true,
    temperature = opts.temperature,
    max_tokens = opts.max_tokens
  }

  local payload_file = vim.fn.tempname() .. "_payload.json"
  vim.fn.writefile({ vim.json.encode(payload) }, payload_file)

  local cmd = {
    "curl", "-s", "-N",
    "-H", "Content-Type: application/json",
    "-H", "Authorization: Bearer " .. opts.api_key,
    "-d", "@" .. payload_file,
    url
  }

  local complete_response = ""
  
  local function on_stdout(err, chunk)
    if err then
      vim.schedule(function() on_error("数据流读取故障: " .. tostring(err)) end)
      return
    end

    if not chunk or chunk == "" then return end

    local lines = vim.split(chunk, "\n")
    for _, line in ipairs(lines) do
      line = vim.trim(line)
      if vim.startswith(line, "data: ") then
        local json_str = line:sub(7)
        if json_str ~= "[DONE]" then
          local ok, decoded = pcall(vim.json.decode, json_str)
          if ok and decoded.choices and decoded.choices[1] and decoded.choices[1].delta then
            local content = decoded.choices[1].delta.content
            if content and type(content) == "string" then
              complete_response = complete_response .. content
              vim.schedule(function() on_chunk(content) end)
            end
          end
        end
      end
    end
  end

  local function on_exit(obj)
    pcall(os.remove, payload_file)

    if obj.code ~= 0 then
      vim.schedule(function()
        on_error("网络连接断开，Curl 错误代码: " .. obj.code)
      end)
      return
    end

    vim.schedule(function()
      if complete_response == "" then
        on_error("未收到 API 端的有效响应，请核验您的 DeepSeek API Key 状态。")
        return
      end

      -- 检查并运行大模型决定运行的 Neovim 功能
      -- 注意：代码生成分支与全局定位在这里共享相同的工具提取机制，但分支和全局会话各自流向不同的返回闭环
      local active_buf = vim.api.nvim_get_current_buf()
      local tool_run = M.execute_tool_if_any(complete_response, active_buf)
      
      on_complete_wrapper(complete_response, tool_run)
    end)
  end

  -- 发起异步系统进程调用，杜绝任何同步阻塞
  vim.system(cmd, { stdout = on_stdout }, on_exit)
end

return M
