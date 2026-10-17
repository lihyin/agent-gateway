import { timingSafeEqual } from "node:crypto";
import type { IncomingMessage, ServerResponse } from "node:http";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { Bridge } from "./bridge.js";
import { createMcpServer } from "./mcp.js";

export type RemoteConfiguration = {
  publicOrigin: string;
  relayOrigin: string;
  mcpToken: string;
  relayToken: string;
};
function authorized(header: string | undefined, token: string): boolean {
  const expected = Buffer.from(`Bearer ${token}`),
    actual = Buffer.from(header ?? "");
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}
async function body(request: IncomingMessage): Promise<string> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of request) {
    size += Buffer.byteLength(chunk);
    if (size > 131072) throw new Error("oversize");
    chunks.push(Buffer.from(chunk));
  }
  return Buffer.concat(chunks).toString("utf8");
}
export function remoteHandler(bridge: Bridge, config: RemoteConfiguration) {
  const origin = new URL(config.publicOrigin);
  const relay = new URL(config.relayOrigin);
  if (
    origin.protocol !== "https:" ||
    origin.origin !== config.publicOrigin ||
    relay.protocol !== "https:" ||
    relay.origin !== config.relayOrigin ||
    config.mcpToken.length < 32 ||
    config.relayToken.length < 32 ||
    config.mcpToken === config.relayToken
  )
    throw new Error("configuration_required");
  return async (
    request: IncomingMessage,
    response: ServerResponse,
  ): Promise<void> => {
    response.setHeader("Cache-Control", "no-store");
    response.setHeader("X-Content-Type-Options", "nosniff");
    const reply = (status: number, error: string) => {
      response.writeHead(status, { "Content-Type": "application/json" });
      response.end(JSON.stringify({ error }));
    };
    // Preserve the original Host at the TLS reverse proxy. Never trust forwarded-host.
    if (
      request.headers.host !== origin.host ||
      (request.headers.origin && request.headers.origin !== origin.origin)
    ) {
      reply(403, "forbidden");
      return;
    }
    if (request.url !== "/mcp" && request.url !== "/transport/sync") {
      reply(404, "not_found");
      return;
    }
    const isMcp = request.url === "/mcp";
    if (
      !authorized(
        request.headers.authorization,
        isMcp ? config.mcpToken : config.relayToken,
      )
    ) {
      response.setHeader("WWW-Authenticate", "Bearer");
      reply(401, "unauthorized");
      return;
    }
    if (request.method !== "POST") {
      response.setHeader("Allow", "POST");
      reply(405, "method_not_allowed");
      return;
    }
    const type = request.headers["content-type"]?.split(";")[0];
    if (type !== (isMcp ? "application/json" : "application/jose")) {
      reply(415, "unsupported_media_type");
      return;
    }
    try {
      const input = await body(request);
      if (!isMcp) {
        const result = await bridge.sync(input, config.relayOrigin);
        response.writeHead(200, { "Content-Type": "application/json" });
        response.end(JSON.stringify(result));
        return;
      }
      const parsed: unknown = JSON.parse(input);
      // Batch size and per-message complexity are bounded before SDK dispatch.
      if (Array.isArray(parsed)) {
        reply(400, "invalid_request");
        return;
      }
      const server = createMcpServer(bridge, true);
      const transport = new StreamableHTTPServerTransport({
        sessionIdGenerator: undefined,
        enableJsonResponse: true,
      });
      try {
        await server.connect(transport);
        await transport.handleRequest(request, response, parsed);
      } finally {
        await server.close();
      }
    } catch (error) {
      if (!response.headersSent)
        reply(
          error instanceof Error && error.message === "oversize" ? 413 : 400,
          "invalid_request",
        );
      else response.end();
    }
  };
}
