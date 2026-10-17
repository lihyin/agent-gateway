import {
  boundedText,
  publicOrigin,
  verifySyncProof,
  type PairingConfiguration,
} from "./foreground.js";

export interface RelayEnvironment {
  ENVIRONMENT?: string;
  RELEASE_SHA?: string;
  BRIDGE_ORIGIN?: string;
  RELAY_ORIGIN?: string;
  BRIDGE_RELAY_TOKEN?: string;
  PAIRING_CONFIG?: string;
}

export default {
  async fetch(request: Request, env: RelayEnvironment): Promise<Response> {
    const headers = {
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
    };
    const url = new URL(request.url);
    if (
      url.pathname === "/v1/device/sync" &&
      env.BRIDGE_ORIGIN &&
      env.RELAY_ORIGIN &&
      env.BRIDGE_RELAY_TOKEN &&
      env.PAIRING_CONFIG
    ) {
      if (request.method !== "POST")
        return Response.json(
          { error: "method_not_allowed" },
          { status: 405, headers: { ...headers, Allow: "POST" } },
        );
      if (
        request.headers.get("content-type") !== "application/jose" ||
        url.search
      )
        return Response.json(
          { error: "invalid_request" },
          { status: 400, headers },
        );
      try {
        const origin = publicOrigin(env.RELAY_ORIGIN);
        const bridge = publicOrigin(env.BRIDGE_ORIGIN);
        if (url.origin !== origin || env.BRIDGE_RELAY_TOKEN.length < 32)
          throw new Error("configuration_required");
        const compact = await boundedText(request, 92000);
        await verifySyncProof(
          compact,
          JSON.parse(env.PAIRING_CONFIG) as PairingConfiguration,
          origin,
        );
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), 10000);
        try {
          const upstream = await fetch(`${bridge}/transport/sync`, {
            method: "POST",
            headers: {
              "Content-Type": "application/jose",
              Authorization: `Bearer ${env.BRIDGE_RELAY_TOKEN}`,
            },
            body: compact,
            redirect: "error",
            signal: controller.signal,
          });
          if (!upstream.ok) throw new Error("forward_failed");
          const output = JSON.parse(await boundedText(upstream, 8192));
          // The upstream response must never contain approved plaintext.
          if (
            Object.keys(output).sort().join(",") !== "acknowledged,envelope" ||
            !(
              output.acknowledged === null ||
              typeof output.acknowledged === "string"
            ) ||
            !(
              output.envelope === null ||
              (Object.keys(output.envelope).sort().join(",") ===
                "context,jwe" &&
                typeof output.envelope.jwe === "string" &&
                new TextEncoder().encode(JSON.stringify(output.envelope))
                  .length <= 3500)
            )
          )
            throw new Error("forward_failed");
          return Response.json(output, { headers });
        } catch (error) {
          if (error instanceof Error && error.message === "oversize")
            throw error;
          throw new Error("forward_failed");
        } finally {
          clearTimeout(timeout);
        }
      } catch (error) {
        const code = error instanceof Error ? error.message : "unauthorized";
        const status =
          code === "oversize"
            ? 413
            : code === "forward_failed" || code === "configuration_required"
              ? 503
              : 401;
        return Response.json(
          {
            error:
              status === 413
                ? "oversize"
                : status === 503
                  ? "transport_unavailable"
                  : "unauthorized",
          },
          { status, headers },
        );
      }
    }
    if (url.pathname !== "/health") {
      return Response.json({ error: "not_found" }, { status: 404, headers });
    }
    if (request.method !== "GET") {
      return Response.json(
        { error: "method_not_allowed" },
        { status: 405, headers: { ...headers, Allow: "GET" } },
      );
    }
    return Response.json(
      {
        status: "ok",
        service: "agent-gateway-relay",
        environment: env.ENVIRONMENT ?? "local",
        revision: env.RELEASE_SHA ?? "local",
        sourceAccessEnabled: false,
      },
      { headers },
    );
  },
};
