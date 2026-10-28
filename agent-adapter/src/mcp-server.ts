import { Readable } from "node:stream";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { createMcpServer } from "./mcp.js";
import { openBridge } from "./store.js";
import { relayRequest } from "./relay-client.js";

async function main() {
  const path = process.env.GATEWAY_AGENT_STATE;
  if (!path) throw new Error("configuration_required");
  const { bridge, close } = await openBridge(path);
  const origin = process.env.RELAY_URL;
  const controller = new AbortController();
  const active = new Map<string, Promise<unknown>>();
  const errors = new Map<string, string>();
  const server = createMcpServer(
    bridge,
    Boolean(origin),
    (id) => {
      if (!origin || active.has(id)) return;
      for (const savedId of errors.keys())
        if (!bridge.state.jobs[savedId]) errors.delete(savedId);
      errors.delete(id);
      const task = relayRequest(bridge, id, origin, controller.signal)
        .catch((error) => {
          if (
            error instanceof Error &&
            error.message === "relay_pairing_rejected"
          )
            errors.set(id, error.message);
          if (!controller.signal.aborted)
            process.stderr.write(
              error instanceof Error &&
                error.message === "relay_pairing_rejected"
                ? "The relay rejected the saved pairing. Ask the user for a fresh iPhone setup message, stop this MCP process, then use pair --replace and enable phone notifications.\n"
                : "Relay delivery incomplete; check configuration and retry the same request before expiry.\n",
            );
        })
        .finally(() => {
          active.delete(id);
        });
      active.set(id, task);
    },
    (id) => errors.get(id),
  );
  let closed = false;
  const shutdown = async () => {
    if (closed) return;
    closed = true;
    controller.abort();
    await server.close();
    await Promise.allSettled(active.values());
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
