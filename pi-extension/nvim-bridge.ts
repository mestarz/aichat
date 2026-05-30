/**
 * nvim-bridge：pi 扩展与「正在运行的 Neovim」之间的瘦通道。
 *
 * 设计：所有编辑器逻辑都在 nvim 插件 (lua/aichat/server.lua) 这一层；
 * 本桥接只负责把 (toolName, params) 通过 nvim 的 msgpack-RPC socket 转发过去，
 * 再把返回结果原样带回。扩展里不含任何编辑器逻辑。
 *
 * socket 地址由 nvim 插件在拉起 pi 时通过环境变量 AICHAT_NVIM_SOCKET 注入。
 */
import { attach } from "neovim";
import { createConnection } from "node:net";

export interface NvimBridge {
  /** 调用 nvim 服务端暴露的某个能力（present_files / edit_file …）。 */
  call(name: string, params: Record<string, unknown>): Promise<unknown>;
  /** 获取 nvim 服务端的工具清单（供动态发现，可选）。 */
  listTools(): Promise<unknown>;
}

const CALL_LUA = "local n, p = ...; return require('aichat.server').call(n, p)";
const LIST_LUA = "return require('aichat.server').list_tools()";

export async function connectNvimBridge(
  socket: string | undefined = process.env.AICHAT_NVIM_SOCKET,
): Promise<NvimBridge> {
  if (!socket) {
    throw new Error("AICHAT_NVIM_SOCKET 未设置：当前不在 aichat.nvim 拉起的会话中，无法连接 Neovim。");
  }

  // 自建 socket 并 unref()：这条到 nvim 的长连接不应阻塞 pi 进程退出，
  // 否则 agent 跑完后 pi 仍因 socket 句柄存活而不退出，前端的 on_exit/思考动画永不结束。
  const client = createConnection(socket);
  client.unref();

  const nvim = attach({ reader: client, writer: client });

  const exec = (code: string, args: unknown[]): Promise<unknown> =>
    nvim.request("nvim_exec_lua", [code, args]);

  return {
    call(name, params) {
      return exec(CALL_LUA, [name, params ?? {}]);
    },
    listTools() {
      return exec(LIST_LUA, []);
    },
  };
}
