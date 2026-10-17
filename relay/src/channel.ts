import type {
  DurableObjectState,
  WebSocket as Socket,
} from "@cloudflare/workers-types";
import {
  push,
  seconds,
  type Context,
  type DirectEnvironment,
  type Envelope,
} from "./direct.js";
declare const WebSocketPair: { new (): { 0: Socket; 1: Socket } };

// Live transport only: no Storage API, payload attachments, database or mailbox.
export class RequestChannel {
  constructor(
    private readonly ctx: DurableObjectState,
    private readonly env: DirectEnvironment,
  ) {}
  async fetch(request: Request): Promise<Response> {
    const headers = { "Cache-Control": "no-store" };
    if (new URL(request.url).pathname === "/open") {
      const input = JSON.parse(
        request.headers.get("X-Gateway-Input") ?? "null",
      ) as { envelope: Envelope; pushToken: string };
      const context = input.envelope.context;
      const digest = Array.from(
        new Uint8Array(
          await crypto.subtle.digest(
            "SHA-256",
            new TextEncoder().encode(input.envelope.jwe),
          ),
        ),
        (byte) => byte.toString(16).padStart(2, "0"),
      ).join("");
      for (const socket of this.ctx.getWebSockets()) {
        const previous = socket.deserializeAttachment() as {
          context: Context;
          digest: string;
        };
        if (
          JSON.stringify(previous.context) !== JSON.stringify(context) ||
          previous.digest !== digest
        )
          return Response.json({ error: "replay" }, { status: 409, headers });
        socket.close(1000, "reconnected");
      }
      const pair = new WebSocketPair();
      this.ctx.acceptWebSocket(pair[1]);
      pair[1].serializeAttachment({ context, digest });
      // Bound live resources even if a client ignores the original expiry.
      setTimeout(
        () => {
          try {
            pair[1].close(1000, "expired");
          } catch {
            /* Already closed. */
          }
        },
        Math.max(0, (context.expiresAt - seconds()) * 1000),
      );
      try {
        await push(this.env, input.pushToken, input.envelope);
      } catch {
        pair[1].close(1011, "transport_unavailable");
        return Response.json(
          { error: "transport_unavailable" },
          { status: 503, headers },
        );
      }
      return new Response(null, {
        status: 101,
        webSocket: pair[0],
      } as ResponseInit);
    }
    const result = (await request.json()) as Envelope;
    let sent = false;
    for (const socket of this.ctx.getWebSockets()) {
      const original = (socket.deserializeAttachment() as { context: Context })
        .context;
      const c = result.context;
      if (original.expiresAt <= seconds()) {
        socket.close(1000, "expired");
        continue;
      }
      if (
        c.requestId !== original.requestId ||
        c.pairingEpoch !== original.pairingEpoch ||
        c.sender !== original.recipient ||
        c.recipient !== original.sender ||
        c.issuedAt !== original.issuedAt ||
        c.expiresAt !== original.expiresAt
      )
        continue;
      try {
        socket.send(JSON.stringify(result));
        sent = true;
      } catch {
        /* Endpoint retries within original expiry. */
      }
    }
    return Response.json(
      sent ? { status: "handed_off" } : { error: "agent_offline" },
      { status: sent ? 202 : 503, headers },
    );
  }
  webSocketMessage(socket: Socket) {
    socket.close(1008, "receive_only");
  }
  webSocketClose(socket: Socket, code: number) {
    socket.close(code === 1006 ? 1000 : code, "closed");
  }
  webSocketError(socket: Socket) {
    socket.close(1011, "transport_unavailable");
  }
}
