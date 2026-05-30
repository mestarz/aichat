-- aichat.nvim 子代理(pi)调度核心
-- 把 pi 当作完整的原生 agent 来驱动：用 `pi -p --mode json` 拉起，解析其 NDJSON
-- 事件流做流式渲染；工具调用交给 pi 原生 function calling（present_files / edit_file
-- 由 pi 扩展注册，经 socket 回连本插件的 lua/aichat/server.lua 执行）。
local M = {}
local config = require("aichat.config")
local context = require("aichat.context")

-- 解析出插件根目录（用于定位 pi 扩展文件）
local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(src, ":h:h:h")
end

-- 当前会话 id（让多轮对话落到同一个 pi 会话，由 pi 自管历史）
M.session_id = nil

local function ensure_session()
  if not M.session_id then
    M.session_id = "aichat-" .. tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999))
  end
  return M.session_id
end

-- 重置会话：开一个全新的 pi 会话
function M.reset_history()
  M.session_id = nil
  ensure_session()
end

-- 确保有一个可供子进程回连的 RPC server 地址
local function ensure_server()
  local addr = vim.v.servername
  if not addr or addr == "" then
    addr = vim.fn.serverstart()
  end
  return addr
end

-- 兼容旧调用（window.lua 的欢迎语用到）
function M.get_editor_context(active_buf)
  return context.get_editor_context(active_buf)
end

-- 拉起 pi 并解析 --mode json 事件流
-- cbs: { on_chunk, on_tool_start, on_tool_end, on_complete, on_error }
local function run_pi(user_prompt, active_buf, cbs)
  local opts = config.get()
  local pi_bin = opts.pi_agent_path or "pi"
  local ext_path = plugin_root() .. "/pi-extension/aichat-nvim.ts"
  local socket = ensure_server()

  -- 系统提示词只放恒定的行为约束 —— 字节级稳定，保证 provider 缓存前缀命中。
  -- 易变上下文（当前文件/光标/可编辑代码）一律拼到「用户消息尾部」。
  local system_text = context.behavior_prompt
  local message = user_prompt .. "\n\n" .. context.build_context_text(active_buf)

  local cmd = {
    pi_bin,
    "-p",
    "--mode", "json",
    "--exclude-tools", "edit,write",
    "-e", ext_path,
    "--session-id", ensure_session(),
    "--append-system-prompt", system_text,
    message,
  }
  -- 模型预配置（provider/model），插在 message 之前
  if opts.pi_provider and opts.pi_provider ~= "" then
    table.insert(cmd, #cmd, "--provider")
    table.insert(cmd, #cmd, opts.pi_provider)
  end
  if opts.pi_model and opts.pi_model ~= "" then
    table.insert(cmd, #cmd, "--model")
    table.insert(cmd, #cmd, opts.pi_model)
  end
  if opts.pi_extra_args then
    for _, a in ipairs(opts.pi_extra_args) do
      table.insert(cmd, #cmd, a) -- 插在 message 之前
    end
  end

  local stdout_buf = ""
  local full_text = {}

  local function dispatch(event)
    local t = event.type
    if t == "message_update" then
      local ame = event.assistantMessageEvent
      if ame and ame.type == "text_delta" and type(ame.delta) == "string" then
        table.insert(full_text, ame.delta)
        if cbs.on_chunk then cbs.on_chunk(ame.delta) end
      end
    elseif t == "tool_execution_start" then
      if cbs.on_tool_start then cbs.on_tool_start(event.toolName, event.args) end
    elseif t == "tool_execution_end" then
      if cbs.on_tool_end then cbs.on_tool_end(event.toolName, event.result, event.isError) end
    end
  end

  local function process_line(line)
    line = vim.trim(line)
    if line == "" then return end
    local ok, decoded = pcall(vim.json.decode, line)
    if ok and type(decoded) == "table" and decoded.type then
      vim.schedule(function() dispatch(decoded) end)
    end
  end

  local function on_stdout(err, chunk)
    if err then
      vim.schedule(function()
        if cbs.on_error then cbs.on_error("读取 pi 输出出错: " .. tostring(err)) end
      end)
      return
    end
    if not chunk or chunk == "" then return end
    stdout_buf = stdout_buf .. chunk
    while true do
      local nl = stdout_buf:find("\n")
      if not nl then break end
      local line = stdout_buf:sub(1, nl - 1)
      stdout_buf = stdout_buf:sub(nl + 1)
      process_line(line)
    end
  end

  local function on_exit(obj)
    if stdout_buf ~= "" then process_line(stdout_buf) end
    vim.schedule(function()
      if obj.code ~= 0 then
        local msg = (obj.stderr and obj.stderr ~= "") and obj.stderr
          or ("pi 异常退出，错误码: " .. tostring(obj.code) .. "。请确认 pi 已安装并已配置模型 API key。")
        if cbs.on_error then cbs.on_error(msg) end
        return
      end
      if cbs.on_complete then cbs.on_complete(table.concat(full_text)) end
    end)
  end

  vim.system(cmd, {
    stdout = on_stdout,
    stderr = true,
    text = true,
    env = { AICHAT_NVIM_SOCKET = socket },
  }, on_exit)
end

-- 发送消息主入口。pi 自身完成「分析 → 调工具 → 继续」的完整 agent 循环，
-- 插件只需发一次、消费事件流，无需再手动多轮回灌。
function M.send_message(user_prompt, active_buf, cbs)
  run_pi(user_prompt, active_buf, cbs or {})
end

return M
