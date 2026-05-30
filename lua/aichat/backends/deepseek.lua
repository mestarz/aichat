-- aichat.nvim 原生 DeepSeek HTTP 后端执行器 (无任何业务冗余，纯净执行端)
local M = {}
local config = require("aichat.config")

-- 执行纯粹的 API 进程调用与 SSE 流式输出读取
function M.call_api(messages_payload, on_chunk, on_complete, on_error)
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
      on_complete(complete_response)
    end)
  end

  -- 发起异步 curl 请求
  vim.system(cmd, { stdout = on_stdout }, on_exit)
end

return M
