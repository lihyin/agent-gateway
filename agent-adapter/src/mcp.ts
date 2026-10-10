import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { Bridge } from "./bridge.js";
import type { Envelope } from "./crypto.js";

const knownErrors = new Set([
  "unpaired",
  "capacity",
  "expired",
  "invalid_request",
  "invalid_result",
  "replay",
  "unknown_request",
  "storage_unavailable",
]);
async function response(task: () => Promise<unknown>) {
  try {
    const output = (await task()) as Record<string, unknown>;
    return {
      content: [{ type: "text" as const, text: JSON.stringify(output) }],
      structuredContent: output,
    };
  } catch (error) {
    const code =
      error instanceof Error && knownErrors.has(error.message)
        ? error.message
        : "operation_failed";
    return {
      content: [
        { type: "text" as const, text: JSON.stringify({ error: code }) },
      ],
      isError: true,
    };
  }
}
export function createMcpServer(bridge: Bridge): McpServer {
  const server = new McpServer(
    { name: "agent-gateway", version: "1.0.0" },
    {
      maxToolInputElements: 64,
      instructions:
        "Device-owned Gmail approval. Requests require foreground encrypted transfer to the paired iPhone and explicit device consent. Pending review is not a completed search. Only verified device-approved results are returned. Pairing is operator-managed; no source credentials are accepted.",
    },
  );
  server.registerTool(
    "gmail_request_preview",
    {
      title: "Request approved Gmail preview",
      description:
        "Create a bounded encrypted Gmail search request for the paired iPhone. This stores a pending job; it does not fetch Gmail or approve disclosure. Transfer the returned envelope to the phone. Reuse requestId and identical arguments on retry. Results expire after five minutes.",
      inputSchema: z
        .object({
          requestId: z.string().uuid(),
          query: z.string().trim().min(1).max(200),
          purpose: z.string().trim().min(1).max(200),
          fields: z
            .array(z.enum(["id", "date", "subject", "from", "snippet"]))
            .min(1)
            .max(5),
          since: z.number().int().nonnegative(),
          until: z.number().int().nonnegative(),
          maxResults: z.number().int().min(1).max(10),
        })
        .strict(),
      annotations: {
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    async ({ requestId, ...arguments_ }) =>
      response(() =>
        bridge.request(
          { source: "gmail", operation: "search", ...arguments_ },
          requestId,
        ),
      ),
  );
  server.registerTool(
    "gateway_request_status",
    {
      title: "Get device review status",
      description:
        "Return pending review, expiry, denial, or the verified device-approved result for a known request. Pending includes the same encrypted request for foreground transfer. Does not contact Gmail or repeat retrieval.",
      inputSchema: z.object({ requestId: z.string().uuid() }).strict(),
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    async ({ requestId }) => response(() => bridge.status(requestId)),
  );
  server.registerTool(
    "gateway_submit_encrypted_result",
    {
      title: "Receive encrypted device result",
      description:
        "Accept an encrypted result exported from the paired iPhone. Verify signature, pinned identity, request context, expiry and result scope before returning approved data. Denials return no source data. No plaintext result or approval override is accepted.",
      inputSchema: z
        .object({ envelope: z.string().min(1).max(65536) })
        .strict(),
      annotations: {
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    async ({ envelope }) =>
      response(async () => {
        if (Buffer.byteLength(envelope, "utf8") > 65536)
          throw new Error("invalid_request");
        return bridge.submit(JSON.parse(envelope) as Envelope);
      }),
  );
  return server;
}
