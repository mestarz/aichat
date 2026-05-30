-- aichat.nvim 智能 Pi-Agent 终端代理服务集成后端 (双上下文 + 深度工具注入)
local M = {}
local config = require("aichat.config")
local tools = require("aichat.tools")


-- 全局会话历史记录列表 (Track A)
M.global_history = {}

-- 重置会话历史
function M.reset_history()
  M.global_history = {}
end

-- 全局 512K 历史剪裁逻辑 (Track A)
local function prune_global_history()
  local opts = config.get()
  local limit_chars = opts.global_context_limit * 4

  local total_chars = 0
  for _, msg in ipairs(M.global_history) do
    total_chars = total_chars + #msg.content
  end

  if total_chars > limit_chars and #M.global_history > 2 then
    local total_items = #M.global_history
    local remaining_count = total_items - 1
    local to_remove = math.floor(remaining_count / 2)
    
    if to_remove > 0 then
      for _ = 1, to_remove do
        table.remove(M.global_history, 2)
      end
      
      vim.schedule(function()
        vim.notify("󰚩 [aichat.nvim] Pi-Agent 全局上下文已超过 512K，已自动裁剪前半部旧会话以释放缓存！", vim.log.levels.WARN)
      end)
    end
  end
end

-- 获取活跃 Buffer 状态
local function get_editor_context(active_buf)
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
    
    local wins = vim.api.nvim_list_wins()
    for _, win in ipairs(wins) do
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == active_buf then
        local cursor = vim.api.nvim_win_get_cursor(win)
        ctx.cursor_line = cursor[1]
        ctx.cursor_col = cursor[2]
        break
      end
    end

    local line_count = vim.api.nvim_buf_line_count(active_buf)
    local start_line = math.max(0, ctx.cursor_line - 75)
    local end_line = math.min(line_count, ctx.cursor_line + 75)
    local lines = vim.api.nvim_buf_get_lines(active_buf, start_line, end_line, false)
    ctx.buffer_lines = table.concat(lines, "\n")
  end

  return ctx
end

-- 判定是否为编辑/写入任务
local function is_code_generation_task(prompt)
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

-- 解析 Pi-Agent stdout 中输出的 JSON 工具调用指令
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

-- 衍生（Spawn）本地 Pi-Agent 进程通信并流式读取 stdout
local function run_pi_process(final_prompt, on_chunk, on_complete_wrapper, on_error)
  local opts = config.get()
  local pi_bin = opts.pi_agent_path or "pi"

  -- 构造命令行，直接通过 pi CLI 运行提问
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
        on_error("Pi-Agent 运行异常退出，错误码: " .. obj.code .. "。请检查是否安装了 pi 命令行代理工具。")
      end)
      return
    end

    vim.schedule(function()
      local active_buf = vim.api.nvim_get_current_buf()
      -- 解析 Pi-Agent 在终端流式输出中做出的工具调用，由 Neovim 插件执行原生操作
      local tool_run = execute_tool_if_any(complete_response, active_buf)
      on_complete_wrapper(complete_response, tool_run)
    end)
  end

  -- 使用 Neovim 异步进程模型启动 Pi-Agent
  vim.system(cmd, { stdout = on_stdout }, on_exit)
end

-- 发送流式信息入口
function M.send_message(user_prompt, active_buf, on_chunk, on_complete, on_error)
  local ctx = get_editor_context(active_buf)

  -- ==========================================
  -- 路线 A: 判定为在当前活跃文件进行局部代码写入生成任务
  -- 【切出临时分支】：启动轻量化分支进程，仅提供局部 buffer 修改与写入，保存撤销历史与即时界面渲染
  -- ==========================================
  if is_code_generation_task(user_prompt) and active_buf then
    local branch_prompt = string.format(
      "【Pi-Agent 代码生成分支】\n当前活动代码文件: %s\n行内代码邻近内容:\n```%s\n%s\n```\n光标所在行号: %d\n\n修改生成任务指令: %s\n\n"
      .. "【重要指示】：请直接调用 edit_buffer (精确搜索替换) 或 insert_at_cursor (光标行内写入) 工具，以 JSON 格式代码块输出。本分支请只输出 JSON 工具块本身，严禁任何废话解释！",
      ctx.file_path,
      ctx.file_type,
      ctx.buffer_lines,
      ctx.cursor_line,
      user_prompt
    )

    run_pi_process(branch_prompt, on_chunk, function(full_response, tool_run)
      local merge_summary = ""
      if tool_run then
        merge_summary = string.format(
          "🛠️ 【Pi-Agent 分支成功修改代码】\n执行工具: %s\n文件: %s\n执行结果: %s",
          tool_run.tool,
          ctx.file_path,
          tool_run.result.status == "success" and "成功" or "失败"
        )
      else
        merge_summary = string.format(
          "💬 【Pi-Agent 运行结束】\n回复摘要: %s",
          full_response:sub(1, 150) .. "..."
        )
      end

      -- 同步给全局跟踪记忆
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
  -- 路线 B: 全局解析 / 代码逻辑定位 (Track A)
  -- 保持全局连续的 512k 缓存上下文，并在第一轮扫描所有文件让 Pi-Agent 彻底拥有全局结构感知！
  -- ==========================================
  if #M.global_history == 0 then
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

  table.insert(M.global_history, { role = "user", content = user_prompt })
  prune_global_history()

  -- 构造包含历史记录的增量提问
  local history_str = ""
  for _, item in ipairs(M.global_history) do
    history_str = history_str .. string.format("\n【%s】:\n%s\n", item.role == "user" and "用户提问" or "历史背景", item.content)
  end

  local final_global_prompt = history_str .. "\n\n【最新提问指令】:\n" .. user_prompt
    .. "\n\n【重要指示】：如果你要检索定位代码，请使用 find_files 或 grep_search 工具。插件会自动在 Neovim 右侧弹出全中文的 [代码定位结果] 面板，支持回车跳转与 p 键预览！如果要读取代码，请使用 read_file 模块。"

  run_pi_process(final_global_prompt, on_chunk, function(full_response, tool_run)
    table.insert(M.global_history, { role = "assistant", content = full_response })
    prune_global_history()

    if tool_run then
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
