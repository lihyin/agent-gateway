import { Readable } from "node:stream";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { createMcpServer } from "./mcp.js";
import { openBridge } from "./store.js";

async function main() {
  const path = process.env.GATEWAY_AGENT_STATE;
  if (!path) throw new Error("configuration_required");
  const { bridge, close } = await openBridge(path);
  const server = createMcpServer(bridge);
  let closed = false;
  const shutdown = async () => {
    if (closed) return;
    closed = true;
    await server.close();
    await close();
  };
  async function* boundedInput() {
    let pending = Buffer.alloc(0);
    for await (const chunk of process.stdin) {
      pending = Buffer.concat([pending, Buffer.from(chunk)]);
      let newline;
      while ((newline = pending.indexOf(10)) >= 0) {
        if (newline > 131072) throw new Error("input_limit");
        yield pending.subarray(0, newline + 1);
        pending = pending.subarray(newline + 1);
      }
      if (pending.length > 131072) throw new Error("input_limit");
    }
    if (pending.length) throw new Error("invalid_input");
  }
  const input = Readable.from(boundedInput());
  input.on("error", () => {
    process.stderr.write("MCP input rejected.\n");
    void shutdown().finally(() => {
      process.exitCode = 1;
      process.stdin.destroy();
    });
  });
  process.on("SIGINT", () => {
    void shutdown().finally(() => process.exit(0));
  });
  process.on("SIGTERM", () => {
    void shutdown().finally(() => process.exit(0));
  });
  try {
    await server.connect(new StdioServerTransport(input, process.stdout));
    input.on("end", () => {
      void shutdown();
    });
  } catch {
    await shutdown();
    throw new Error("startup_failed");
  }
}
main().catch(() => {
  process.stderr.write(
    "MCP server could not start. Check state path, permissions, and exclusive lock.\n",
  );
  process.exitCode = 1;
});
