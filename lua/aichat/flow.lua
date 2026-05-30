-- aichat.nvim 流程图渲染器（确定性 ASCII 布局）
-- 目的：让 AI 只输出「逻辑描述」（节点 + 边），由 Lua 计算对齐、画框、连箭头，
-- 从而把昂贵的「对齐推理 / 视觉冗余 token」从模型侧转移到本地零成本渲染。
--
-- 输入语法（每行一条，紧凑、token 极少）：
--   A -> B                父节点 A 指向子节点 B（线性流程）
--   A -> B : 标签          边上带说明文字（如 成功/失败）
--   节点内多行：用字面量 \n 分隔，例如  window.lua\n用户输入 -> ai.lua\nsend()
--   也允许单独成行只声明一个节点（无箭头）。
-- 第一版聚焦「线性流程」：按节点首次出现顺序竖向排布、方框 + │ + ▼ 连接。
local F = {}

local function dwidth(s)
  return vim.fn.strdisplaywidth(s)
end

-- 把节点 label 中的字面量 \n 还原为多行
local function split_node_lines(label)
  local parts = {}
  for seg in (label .. "\\n"):gmatch("(.-)\\n") do
    table.insert(parts, vim.trim(seg))
  end
  -- 去掉末尾可能的空段
  while #parts > 1 and parts[#parts] == "" do
    table.remove(parts)
  end
  if #parts == 0 then parts = { label } end
  return parts
end

-- 右侧补空格到指定显示宽度（左对齐）
local function pad_right(s, w)
  local pad = w - dwidth(s)
  if pad > 0 then s = s .. string.rep(" ", pad) end
  return s
end

-- 解析输入文本为：有序节点列表 + 边列表
local function parse(spec)
  local seen, order, edges = {}, {}, {}
  local function add_node(n)
    if not seen[n] then
      seen[n] = true
      table.insert(order, n)
    end
  end
  for _, raw in ipairs(vim.split(spec, "\n", { plain = true })) do
    local line = vim.trim(raw)
    if line ~= "" then
      local lhs, rhs = line:match("^(.-)%s*%->%s*(.+)$")
      if lhs then
        local target, elabel = rhs, nil
        local t2, lab = rhs:match("^(.-)%s*:%s*(.+)$")
        if t2 and t2 ~= "" then
          target, elabel = t2, lab
        end
        lhs = vim.trim(lhs)
        target = vim.trim(target)
        add_node(lhs)
        add_node(target)
        table.insert(edges, { from = lhs, to = target, label = elabel })
      else
        add_node(line)
      end
    end
  end
  return order, edges
end

-- 渲染单个节点方框，返回行数组与框宽（含边框）
local function render_box(label)
  local lines = split_node_lines(label)
  local inner = 0
  for _, l in ipairs(lines) do
    inner = math.max(inner, dwidth(l))
  end
  inner = inner + 4 -- 左右各留 2 空格
  local out = {}
  table.insert(out, "+" .. string.rep("-", inner) .. "+")
  for _, l in ipairs(lines) do
    table.insert(out, "|" .. pad_right("  " .. l, inner) .. "|")
  end
  table.insert(out, "+" .. string.rep("-", inner) .. "+")
  return out, inner + 2
end

-- 判断是否像「逻辑描述」（含 -> 箭头）。否则按原样当作手绘 ASCII 处理。
function F.looks_like_spec(content)
  return type(content) == "string" and content:find("%->") ~= nil
end

local H_GAP = 4 -- 同层方框之间的水平间距
local V_GAP = 3 -- 层与层之间的垂直间距（茎 + 母线 + 箭头，留出分叉点）

-- 字符画布：以「显示列」为坐标的稀疏网格，自动扩展，支持连线交叉合并为 +。
local function new_canvas()
  return { rows = {}, prot = {} }
end

local function canvas_get(c, y, x)
  local row = c.rows[y]
  return row and row[x] or " "
end

-- 写入一个字符；junction=true 时允许与已有连线合并成十字 +。
-- 受保护（方框）的单元格不被连线覆盖。
local function canvas_set(c, y, x, ch, junction)
  c.rows[y] = c.rows[y] or {}
  c.prot[y] = c.prot[y] or {}
  if c.prot[y][x] then return end -- 不覆盖方框
  local cur = c.rows[y][x]
  if junction and cur and cur ~= " " and cur ~= ch then
    local set = { ["|"] = true, ["-"] = true, ["+"] = true }
    if set[cur] and set[ch] then
      c.rows[y][x] = "+"
      return
    end
  end
  c.rows[y][x] = ch
end

-- 把一个方框（多行字符串、纯 ASCII 边框 + 可能含中文内容）贴到画布并标记保护。
local function canvas_put_box(c, y, x, box_lines)
  for dy, line in ipairs(box_lines) do
    local ry = y + dy - 1
    c.rows[ry] = c.rows[ry] or {}
    c.prot[ry] = c.prot[ry] or {}
    local col = x
    local n = vim.fn.strchars(line)
    for i = 0, n - 1 do
      local chx = vim.fn.strcharpart(line, i, 1)
      local cw = vim.fn.strdisplaywidth(chx)
      c.rows[ry][col] = chx
      c.prot[ry][col] = true
      if cw == 2 then
        c.rows[ry][col + 1] = "\0" -- 宽字符占位：输出时跳过
        c.prot[ry][col + 1] = true
      end
      col = col + cw
    end
  end
end

-- 在画布上写一段水平文字（边标签），不覆盖已有连线/方框。
local function canvas_text(c, y, x, text)
  c.rows[y] = c.rows[y] or {}
  c.prot[y] = c.prot[y] or {}
  local col = x
  local n = vim.fn.strchars(text)
  for i = 0, n - 1 do
    local chx = vim.fn.strcharpart(text, i, 1)
    local cw = vim.fn.strdisplaywidth(chx)
    if (c.rows[y][col] == nil or c.rows[y][col] == " ") and not c.prot[y][col] then
      c.rows[y][col] = chx
      if cw == 2 then c.rows[y][col + 1] = "\0" end
    end
    col = col + cw
  end
end

local function canvas_to_lines(c)
  local out, maxy = {}, 0
  for y, _ in pairs(c.rows) do maxy = math.max(maxy, y) end
  for y = 1, maxy do
    local row = c.rows[y]
    local s = ""
    if row then
      local maxx = 0
      for x, _ in pairs(row) do maxx = math.max(maxx, x) end
      for x = 1, maxx do
        local ch = row[x]
        if ch == "\0" then
          -- 宽字符第二格：跳过
        else
          s = s .. (ch or " ")
        end
      end
    end
    out[y] = (s:gsub("%s+$", ""))
  end
  return out
end

-- 主入口：把逻辑描述渲染成 ASCII 流程图（支持线性 + 分支/合并）。
function F.render(spec)
  local order, edges = parse(spec)
  if #order == 0 then return { "" } end

  -- 邻接 + 入度
  local children = {}
  for _, n in ipairs(order) do children[n] = {} end
  for _, e in ipairs(edges) do
    table.insert(children[e.from], e.to)
  end

  -- 分层：最长路径分层（DAG），对环做迭代上限保护
  local rank = {}
  for _, n in ipairs(order) do rank[n] = 0 end
  for _ = 1, #order do
    local changed = false
    for _, e in ipairs(edges) do
      if (rank[e.to] or 0) < (rank[e.from] or 0) + 1 then
        rank[e.to] = rank[e.from] + 1
        changed = true
      end
    end
    if not changed then break end
  end

  -- 按层分组（层内保持首次出现顺序）
  local layers, maxr = {}, 0
  for _, n in ipairs(order) do
    local r = rank[n]
    layers[r] = layers[r] or {}
    table.insert(layers[r], n)
    maxr = math.max(maxr, r)
  end

  -- 预渲染每个节点的方框，记录尺寸
  local box = {}
  for _, n in ipairs(order) do
    local lines, w = render_box(n)
    box[n] = { lines = lines, w = w, h = #lines }
  end

  -- 每层高度 / 宽度
  local layer_h, layer_w, canvas_w = {}, {}, 0
  for r = 0, maxr do
    local nodes = layers[r] or {}
    local h, w = 0, 0
    for i, n in ipairs(nodes) do
      h = math.max(h, box[n].h)
      w = w + box[n].w
      if i < #nodes then w = w + H_GAP end
    end
    layer_h[r], layer_w[r] = h, w
    canvas_w = math.max(canvas_w, w)
  end

  -- 计算每层 y、每个节点 x/cx/y（层整体水平居中）
  local pos = {}
  local y = 1
  for r = 0, maxr do
    local nodes = layers[r] or {}
    local start_x = 1 + math.floor((canvas_w - (layer_w[r] or 0)) / 2)
    local cx = start_x
    for _, n in ipairs(nodes) do
      pos[n] = { x = cx, y = y, cx = cx + math.floor(box[n].w / 2) }
      cx = cx + box[n].w + H_GAP
    end
    y = y + (layer_h[r] or 0) + V_GAP
  end

  -- 贴方框
  local c = new_canvas()
  for _, n in ipairs(order) do
    canvas_put_box(c, pos[n].y, pos[n].x, box[n].lines)
  end

  -- 走线：父 -> 子。先竖直离开父框，水平母线对齐到子列，再竖直进入子框，箭头收尾。
  for _, e in ipairs(edges) do
    local p, ch_ = e.from, e.to
    if pos[p] and pos[ch_] then
      local rp = rank[p]
      local pbot = pos[p].y + box[p].h - 1
      -- 母线下移一行，使父框与母线之间有一段竖直「茎」，分叉/汇合点更清晰
      local bus = pos[p].y + (layer_h[rp] or box[p].h) + 1
      local ctop = pos[ch_].y
      local pxc, cxc = pos[p].cx, pos[ch_].cx

      -- 父框底 -> 母线行（竖直茎；分叉时这段让「一分为多」的起点醒目）
      for ry = pbot + 1, bus - 1 do canvas_set(c, ry, pxc, "|", true) end

      if pxc == cxc then
        canvas_set(c, bus, pxc, "|", true)
      else
        canvas_set(c, bus, pxc, "+", true)
        canvas_set(c, bus, cxc, "+", true)
        local a, b = math.min(pxc, cxc), math.max(pxc, cxc)
        for x = a + 1, b - 1 do canvas_set(c, bus, x, "-", true) end
      end

      -- 母线 -> 子框顶，箭头
      for ry = bus + 1, ctop - 2 do canvas_set(c, ry, cxc, "|", true) end
      canvas_set(c, ctop - 1, cxc, "v", false)

      -- 边标签：贴在子列右侧的母线行
      if e.label and e.label ~= "" then
        canvas_text(c, bus, cxc + 2, e.label)
      end
    end
  end

  return canvas_to_lines(c)
end

return F
