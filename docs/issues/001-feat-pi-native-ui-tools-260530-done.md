# 001 - feat - pi 原生 agent 化 + 解耦前端工具 + 交互/性能优化

- 日期：2026-05-30
- 类型：feat / refactor
- 状态：done

## 背景

此前把 `pi`（@earendil-works/pi-coding-agent）当普通文本模型用：在 system prompt
里塞 JSON 工具 schema、逼模型输出 ```json``` 块、再用正则解析执行，脆弱且冗余。
本次将插件重构为「pi 原生 function-calling agent + Lua 本地能力服务端」三层解耦架构，
并完成一轮交互 / 性能优化。

## 架构

- **nvim 插件 (Lua) = 本地能力服务端**：仅暴露前端能力，逻辑集中在此层，
  通过 nvim 自带 msgpack-RPC（socket）对外提供 `aichat.server.call(name, params)`。
- **pi extension (TS) = 瘦桥接**：注册工具，execute() 仅把 (name, params) 经 socket
  转发给 Lua 服务端，零编辑器逻辑。
- **上下文模块**：系统提示词只含行为约束（字节稳定，利于 provider 缓存前缀命中）；
  易变上下文拼到用户消息尾部。

## 暴露给 agent 的 5 个工具

1. `present_files(files)`：左侧真实分割窗列出相关文件，每个文件附一句话中文功能介绍
   （多行折行显示，j/k 按文件跳转、跳过解释行，`<CR>` 打开，`q` 关闭）。
2. `present_text(content)`：右上角文本框展示 ≤300 字精简说明（服务端硬截断），
   必须分条罗列；渲染端保留 AI 的换行、仅对超宽行折行并缩进续行。
3. `present_diagram(content, title?)`：右上角展示流程图。AI 只输出紧凑逻辑描述
   （`A -> B [: 标签]`，节点换行用 `\n`），由 `lua/aichat/flow.lua` 本地确定性渲染为
   对齐的 ASCII 框线图，支持线性 + 分支/合并；零外部依赖，省 token、规避对齐推理开销。
4. `goto_location(path, line, col?)`：把光标跳转到可见文件指定行并 `zz` 居中（翻页定位）；
   目标文件不可见时拒绝，提示改用 present_text 说明位置。
5. `edit_file(path, search, replace)`：仅改「当前可见窗口正在显示的文件」，
   明文唯一精确查找替换，活 buffer 编辑可撤销、不直接落盘。

文本框与流程图同处右上角，二者都有时「文字在上、图在下」，自动重排。

## 关键设计决策

- 系统提示词强调：纯文本回答不展示给开发者（会被丢弃/截断），一切要展示的内容必须
  按类型走对应工具。
- pi 进程「一问一进程」，短命；socket server 与 `--session-id` 在单次 nvim 运行内复用。
- session_id **故意不持久化**：每次重开 nvim 都是全新会话（会重新遍历文件），不跨重启续会话。
- pi 扩展 `nvim-bridge.ts` 的 `unref()` 修复：自建 socket 并 `unref`，避免 Node 事件循环
  常驻导致 pi 不退出、spinner 无限转。
- present_files / present_text / present_diagram 均为「同一面板刷新为最新一批」（覆盖语义）。

## 主要文件

- 新增：`lua/aichat/server.lua`、`lua/aichat/context.lua`、`lua/aichat/flow.lua`、`pi-extension/`
- 修改：`lua/aichat/ai.lua`、`lua/aichat/config.lua`、`lua/aichat/window.lua`
- 删除：`lua/aichat/tools.lua`（编辑逻辑并入 server，磁盘检索交给 pi 内置工具）

## 验证

- `luac -p` 全部 Lua 文件语法通过。
- pi 扩展 `tsx` 导入通过。
- headless nvim：present_files（多行介绍 + j/k 跳转）、present_text（保留分条 + 折行缩进 +
  300 字截断）、present_diagram（线性/分支/合并渲染）、goto_location（可见跳转 + 不可见拒绝）、
  文本框/流程图堆叠重排、Esc 关闭全部窗口，均验证通过。
- 早期已完成真实模型 e2e（gpt-5.4-mini）：edit_file + present_files 全链路打通。
