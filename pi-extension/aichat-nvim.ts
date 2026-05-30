/**
 * aichat.nvim pi 扩展（瘦桥接）
 *
 * 给子代理 (pi) 注册两个「前端」工具，二者的真正逻辑都在 nvim 插件里：
 *   1. present_files —— 在编辑器左侧列表展示与提问相关的文件。
 *   2. edit_file     —— 只修改用户当前可见窗口里显示的那个文件（精确查找替换）。
 *
 * 扩展本身不含任何编辑器逻辑，execute() 只是把参数经 msgpack-RPC 转发给
 * lua/aichat/server.lua，再把结果回传给模型。
 *
 * pi 的内置 read/grep/find/ls 仍保留（供 agent 自行分析）；内置 edit/write
 * 由 nvim 插件在启动 pi 时用 --exclude-tools 禁用，确保只能经本扩展改文件。
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { connectNvimBridge, type NvimBridge } from "./nvim-bridge.ts";

function toToolResult(result: unknown) {
  const obj = (result ?? {}) as Record<string, unknown>;
  const status = obj.status === "success" ? "成功" : "失败";
  const message = typeof obj.message === "string" ? obj.message : "";
  return {
    content: [{ type: "text" as const, text: `[${status}] ${message}`.trim() }],
    details: obj,
    isError: obj.status !== "success",
  };
}

export default async function aichatNvimExtension(pi: ExtensionAPI) {
  let bridge: NvimBridge;
  try {
    bridge = await connectNvimBridge();
  } catch {
    // 不在 aichat.nvim 会话中（无 socket），不注册任何工具，静默跳过。
    return;
  }

  pi.registerTool({
    name: "present_files",
    label: "展示相关文件",
    description:
      "在 Neovim 编辑器左侧列表中展示与用户问题相关的文件，供用户直接打开。" +
      "当你通过分析得出一组与用户问题相关的文件时，调用本工具把它们呈现给用户。" +
      "每个文件都必须附带一句话中文功能介绍（description），显示在文件名下方。",
    parameters: Type.Object({
      files: Type.Array(
        Type.Object({
          path: Type.String({ description: "文件路径（相对工作区或绝对路径）" }),
          description: Type.String({ description: "该文件功能的一句话中文介绍（精炼）" }),
        }),
        { description: "相关文件列表，每项含 path 与功能介绍 description" },
      ),
    }),
    async execute(_toolCallId, params) {
      const result = await bridge.call("present_files", { files: params.files });
      return toToolResult(result);
    },
  });

  pi.registerTool({
    name: "present_diagram",
    label: "展示流程图",
    description:
      "在 Neovim 编辑器右上角展示一张流程图。你只需输出【紧凑的逻辑描述】，插件会自动渲染成对齐的 ASCII 框线图——" +
      "千万不要自己用空格/横线手画对齐，那样既慢又费 token。" +
      "语法：每行一条边 `A -> B`，需要边标签写成 `A -> B : 标签`；节点内换行用字面量 \\n（如 `window.lua\\n用户输入`）。" +
      "仅在「用图更能说明流程/架构」时调用；不需要图时不要调用。",
    parameters: Type.Object({
      content: Type.String({
        description:
          "流程图的逻辑描述（不是手画 ASCII！）。每行一条边 `A -> B`，可加 `: 标签`；节点多行用 \\n 分隔。" +
          "例如：开始 -> 读取配置\\n读取配置 -> 校验 : 必填项\\n校验 -> 完成",
      }),
      title: Type.Optional(Type.String({ description: "流程图标题（可选）" })),
    }),
    async execute(_toolCallId, params) {
      const result = await bridge.call("present_diagram", {
        content: params.content,
        title: params.title,
      });
      return toToolResult(result);
    },
  });

  pi.registerTool({
    name: "present_text",
    label: "展示文字说明",
    description:
      "在 Neovim 编辑器右上角的文本框中展示一段精简说明（与流程图同位置，二者都有时文字在上、图在下）。" +
      "填入的内容必须由你自行精简到 300 个字以内（超出会被截断）。" +
      "格式要求：必须分条罗列、每条独立一行、用「- 」或「1. 2. 3.」开头，需要分段时用空行；" +
      "不要写成一大段没有换行的文字。插件会原样保留你的换行与条目结构。" +
      "当需要把光标跳转到某处但目标文件未显示在任何可见窗口时，应改用本工具向开发者说明该功能位于哪个文件、第几行/哪一块，由开发者自行打开。",
    parameters: Type.Object({
      content: Type.String({
        description:
          "已精简到 300 字以内的中文说明，必须分条罗列（每条一行、以「- 」或编号开头，段落间空行），不要写成无换行的一整段。",
      }),
    }),
    async execute(_toolCallId, params) {
      const result = await bridge.call("present_text", {
        content: params.content,
      });
      return toToolResult(result);
    },
  });

  pi.registerTool({
    name: "goto_location",
    label: "跳转到代码位置",
    description:
      "把光标跳转到某个当前可见文件的指定行并居中显示（翻页定位），用于回答「某功能/函数在哪一行/哪一块」。" +
      "只能跳转到当前显示在可见窗口中的文件；若目标文件未显示在任何可见窗口，本工具会返回错误，" +
      "此时应改用 present_text 向开发者说明位置，由开发者自行打开。",
    parameters: Type.Object({
      path: Type.String({
        description: "目标文件路径（必须是当前某个可见窗口中正在显示的文件）",
      }),
      line: Type.Number({ description: "目标行号（从 1 开始）" }),
      col: Type.Optional(Type.Number({ description: "目标列号（从 1 开始，可选）" })),
    }),
    async execute(_toolCallId, params) {
      const result = await bridge.call("goto_location", {
        path: params.path,
        line: params.line,
        col: params.col,
      });
      return toToolResult(result);
    },
  });

  pi.registerTool({
    name: "edit_file",
    label: "编辑当前可见文件",
    description:
      "修改用户当前正在查看（可见窗口中显示）的某个文件的内容，使用精确查找替换。" +
      "只能修改当前可见的文件，禁止跨文件修改，也禁止修改没有显示在窗口里的文件。" +
      "search 必须在该文件中唯一且与原文一字不差。",
    parameters: Type.Object({
      path: Type.String({
        description: "目标文件路径（必须是当前某个可见窗口中正在显示的文件）",
      }),
      search: Type.String({
        description: "待替换的原文片段（需在文件中唯一且一字不差）",
      }),
      replace: Type.String({ description: "替换后的新内容" }),
    }),
    async execute(_toolCallId, params) {
      const result = await bridge.call("edit_file", {
        path: params.path,
        search: params.search,
        replace: params.replace,
      });
      return toToolResult(result);
    },
  });
}
