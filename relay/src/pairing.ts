import type {
  DurableObjectNamespace,
  DurableObjectState,
  WebSocket as Socket,
} from "@cloudflare/workers-types";
import { publicOrigin } from "./foreground.js";
import { selfRegisterPair, type RegistryEnvironment } from "./registry.js";

declare const WebSocketPair: { new (): { 0: Socket; 1: Socket } };
export interface PairingEnvironment extends RegistryEnvironment {
  PAIRINGS?: DurableObjectNamespace;
  RELAY_ORIGIN?: string;
}

export async function pairingFetch(
  request: Request,
  env: PairingEnvironment,
): Promise<Response> {
  const url = new URL(request.url);
  const match = /^\/v1\/pairing\/([a-f0-9]{64})\/(device|agent)$/.exec(
    url.pathname,
  );
  if (!match || !env.PAIRINGS) return new Response(null, { status: 404 });
  try {
    if (url.origin !== publicOrigin(env.RELAY_ORIGIN ?? ""))
      return new Response(null, { status: 404 });
  } catch {
    return new Response(null, { status: 404 });
  }
  if (
    request.method !== "GET" ||
    request.headers.get("Upgrade")?.toLowerCase() !== "websocket" ||
    url.search ||
    request.headers.has("Origin")
  )
    return new Response(null, { status: 400 });
  return (await env.PAIRINGS.get(env.PAIRINGS.idFromName(match[1])).fetch(
    `https://pairing/${match[2]}`,
    { headers: { Upgrade: "websocket" } },
  )) as unknown as Response;
}

// A single live attempt, never a mailbox. No storage, hibernation or payload attachments.
// Object resets invalidate the session; the phone must generate a new random address/code.
export class PairingChannel {
  constructor(
    private readonly ctx: DurableObjectState,
    private readonly env: PairingEnvironment,
  ) {}
  private device?: Socket;
  private agent?: Socket;
  private used = false;
  private frames = new Map<Socket, number>();
  private deadline = 0;
  private timer?: ReturnType<typeof setTimeout>;
  async fetch(request: Request): Promise<Response> {
    const role = new URL(request.url).pathname;
    if (
      role === "/device"
        ? this.used
        : role !== "/agent" ||
          !this.device ||
          this.agent ||
          Date.now() >= this.deadline
    )
      return new Response(null, { status: 409 });
    const pair = new WebSocketPair();
    pair[1].accept();
    this.frames.set(pair[1], 0);
    if (role === "/device") {
      this.used = true;
      this.device = pair[1];
      this.deadline = Date.now() + 1_800_000;
      this.timer = setTimeout(() => this.close(), 1_800_000);
    } else {
      this.agent = pair[1];
      this.device!.send(JSON.stringify({ kind: "joined" }));
    }
    pair[1].addEventListener("message", (event) => {
      const count = (this.frames.get(pair[1]) ?? 0) + 1;
      this.frames.set(pair[1], count);
      const data = event.data;
      if (
        Date.now() >= this.deadline ||
        typeof data !== "string" ||
        new TextEncoder().encode(data).length > 8192 ||
        count > 5
      ) {
        this.close();
        return;
      }
      // Self-registration (see registry.ts): the phone may send one
      // cleartext pairing_record frame presenting its pair record with a
      // device-signed proof. The relay consumes the frame — it is never
      // forwarded to the agent — and stores the record in the
      // PairingRegistry, so no operator step follows a pairing. Without a
      // registry bound the frame closes the session; an invalid proof fails the
      // session closed, like any other protocol violation. The frame
      // counts toward the existing per-socket frame bound (the phone
      // sends at most challenge, ready, receipt, pairing_record).
      if (role === "/device") {
        let frame: { kind?: unknown } | undefined;
        try {
          frame = JSON.parse(data) as { kind?: unknown };
        } catch {
          frame = undefined;
        }
        if (frame?.kind === "pairing_record") {
          if (!this.env.PAIRINGS_REGISTRY) {
            this.close();
            return;
          }
          if (this.env.PAIRINGS_REGISTRY) {
            const registration = (async () => {
              try {
                await selfRegisterPair(
                  this.env,
                  frame,
                  publicOrigin(this.env.RELAY_ORIGIN ?? ""),
                );
              } catch {
                this.close();
              }
            })();
            this.ctx.waitUntil(registration);
          }
          return;
        }
      }
      const peer = role === "/device" ? this.agent : this.device;
      if (!peer) {
        this.close();
        return;
      }
      try {
        peer.send(data);
      } catch {
        this.close();
      }
    });
    pair[1].addEventListener("close", () => this.close());
    pair[1].addEventListener("error", () => this.close());
    return new Response(null, {
      status: 101,
      webSocket: pair[0],
    } as ResponseInit);
  }
  private close() {
    clearTimeout(this.timer);
    for (const socket of [this.device, this.agent]) {
      try {
        socket?.close(1000, "pairing_closed");
      } catch {
        /* Already closed. */
      }
    }
    this.device = undefined;
    // Retain used/agent tombstones in this live object. The device enforces one attempt too.
    this.frames.clear();
  }
}
