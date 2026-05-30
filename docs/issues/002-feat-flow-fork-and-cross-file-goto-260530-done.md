# 002 - feat: 流程图分叉清晰化 + 跨文件跳转

- 类型：feat
- 状态：done
- 日期：260530

## 背景 / 问题
1. `present_diagram` 渲染的分支/合并图中，分叉点紧贴父框，"一分为多/多合为一"的分叉点不够醒目。
2. `present_diagram` 缺少生成约束，AI 容易画得发散、混入不同抽象层级、节点过多。
3. `goto_location` 只能跳转到「当前可见窗口里已显示的文件」，无法跨文件跳转；且跳转后可能停留在插入模式，不便键盘浏览。

## 改动
### flow.lua（分叉点清晰化）
- `V_GAP` 由 2 提升到 3，母线（bus）下移一行，使父框底部与母线之间多出一段竖直「茎」`|`，
  让分叉/汇合的 `+` 节点与父框拉开距离、视觉上更清晰。

### present_diagram 生成约束（context.lua + aichat-nvim.ts）
- 在行为提示词与工具描述中加入要求：
  - 聚焦用户真正问的主线，不塞无关细节；
  - 严格按用户提出的层次粒度组织结构；
  - 节点总数尽量 ≤ 10；
  - 必须是同一抽象层级（同一视图平面）的一张连贯图，不混入不同层级的内容。

### goto_location（server.lua + context.lua + aichat-nvim.ts）
- 跳转后强制 `stopinsert`，进入普通(命令)模式，便于继续键盘浏览。
- 允许跨文件跳转：目标文件未显示在可见窗口时，在主窗口（普通非浮窗、buftype 为空的窗口）`:edit` 打开它；
  文件不存在/不可读，或找不到主窗口时才返回错误。
- 新增强制约束：跨文件跳转（打开的文件不同于跳转前所在文件）后，AI 必须调用 `present_diagram`
  画出「跳转前文件」与「跳转后文件」之间的调用/引用关系并标明方向；两者无关系时改用 `present_text` 说明。
- 同步更新 `list_tools` 描述、behavior_prompt、TS 工具描述与参数说明。

## 验证
- `luac -p` 通过：flow.lua / server.lua / context.lua。
- `tsx` 导入检查通过：aichat-nvim.ts。
- headless 渲染测试：分支/合并图分叉点出现竖直茎，分叉清晰；线性图正常。
- headless goto_location：跨文件在主窗口打开目标文件（opened_new=true），跳转后处于普通模式。
- 测试后已 `git checkout -- .nvimlog` 复原。
