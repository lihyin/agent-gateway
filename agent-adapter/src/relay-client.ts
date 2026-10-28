import WebSocket from "ws";
import type { Bridge } from "./bridge.js";

// Runs as an outbound client in Muse's runtime. Opens no HTTP listener.
export async function relayRequest(
  bridge: Bridge,
  id: string,
  origin: string,
  signal?: AbortSignal,
  connect: (url: string, options: WebSocket.ClientOptions) => WebSocket = (
    url,
    options,
  ) => new WebSocket(url, options),
): Promise<Record<string, unknown>> {
  const url = new URL(origin);
  if (
    url.protocol !== "https:" ||
    url.origin !== origin ||
    url.username ||
    url.password
  )
    throw new Error("configuration_required");
  for (;;) {
    if (signal?.aborted) throw new Error("cancelled");
    const status = await bridge.status(id);
    if (status.status !== "pending_device_review") return status;
    const context = (status.envelope as { context: { expiresAt: number } })
      .context;
    const remaining = context.expiresAt * 1000 - Date.now();
    if (remaining <= 0) return bridge.status(id);
    const authorization = await bridge.relayProof(id, origin);
    const outcome = await new Promise<"retry" | "received">(
      (resolve, reject) => {
        const socket = connect(
          `${origin.replace("https:", "wss:")}/v1/requests`,
          {
            headers: { Authorization: `Bearer ${authorization}` },
            maxPayload: 65536,
            handshakeTimeout: 15000,
            followRedirects: false,
          },
        );
        let finished = false;
        const finish = (outcome: "retry" | "received", error?: Error) => {
          if (finished) return;
          finished = true;
          clearTimeout(timeout);
          signal?.removeEventListener("abort", abort);
          socket.terminate();
          if (error) reject(error);
          else resolve(outcome);
        };
        const timeout = setTimeout(() => finish("retry"), remaining);
        const abort = () => finish("retry", new Error("cancelled"));
        signal?.addEventListener("abort", abort, { once: true });
        if (signal?.aborted) abort();
        socket.on("message", async (data) => {
          try {
            await bridge.submit(JSON.parse(data.toString()));
            finish("received");
          } catch {
            finish("retry", new Error("invalid_result"));
          }
        });
        socket.on("unexpected-response", (_request, response) => {
          response.resume();
          if ([429, 502, 503, 504].includes(response.statusCode ?? 0))
            finish("retry");
          else finish("retry", new Error("relay_configuration_required"));
        });
        socket.on("error", () => finish("retry"));
        socket.on("close", () => finish("retry"));
      },
    );
    if (outcome === "received") return bridge.status(id);
    if (signal?.aborted) throw new Error("cancelled");
    await new Promise<void>((resolve) => {
      const done = () => {
        clearTimeout(timer);
        signal?.removeEventListener("abort", done);
        resolve();
      };
      const timer = setTimeout(
        done,
        Math.min(3000, Math.max(0, context.expiresAt * 1000 - Date.now())),
      );
      signal?.addEventListener("abort", done, { once: true });
    });
  }
}
