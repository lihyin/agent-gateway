import { createServer } from "node:http";
import { openBridge } from "./store.js";
import { remoteHandler } from "./remote.js";

async function main() {
  const path = process.env.GATEWAY_AGENT_STATE;
  if (!path) throw new Error("configuration_required");
  const { bridge, close } = await openBridge(path);
  try {
    const handler = remoteHandler(bridge, {
      publicOrigin: process.env.BRIDGE_ORIGIN ?? "",
      relayOrigin: process.env.RELAY_ORIGIN ?? "",
      mcpToken: process.env.MCP_ACCESS_TOKEN ?? "",
      relayToken: process.env.BRIDGE_RELAY_TOKEN ?? "",
    });
    const server = createServer((request, response) => {
      void handler(request, response);
    });
    server.requestTimeout = 15000;
    server.headersTimeout = 10000;
    server.maxConnections = 100;
    const port = Number(process.env.PORT ?? 8789);
    // Bind loopback by default; expose only behind the configured TLS proxy.
    server.listen(port, process.env.BIND_ADDRESS ?? "127.0.0.1");
    for (const signal of ["SIGINT", "SIGTERM"] as const)
      process.on(signal, () => {
        server.close(() => {
          void close();
        });
        server.closeAllConnections();
      });
    server.on("error", () => {
      void close().finally(() => {
        process.exitCode = 1;
      });
    });
  } catch (error) {
    await close();
    throw error;
  }
}
main().catch(() => {
  process.stderr.write(
    "Remote bridge failed to start. Check configuration and state lock.\n",
  );
  process.exitCode = 1;
});
