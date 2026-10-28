import { directFetch, type DirectEnvironment } from "./direct.js";
import { pairingFetch, type PairingEnvironment } from "./pairing.js";
import { provisioningFetch } from "./registry.js";
export { PairingChannel } from "./pairing.js";
export { RequestChannel } from "./channel.js";
export { PairingRegistry } from "./registry.js";
export interface RelayEnvironment
  extends DirectEnvironment, PairingEnvironment {
  ENVIRONMENT?: string;
  RELEASE_SHA?: string;
}
export default {
  async fetch(request: Request, env: RelayEnvironment): Promise<Response> {
    const headers = {
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
    };
    const path = new URL(request.url).pathname;
    if (path.startsWith("/v1/pairing/")) return pairingFetch(request, env);
    if (path === "/v1/pairings" && request.method === "POST")
      return provisioningFetch(request, env);
    if (
      [
        "/v1/routes",
        "/v1/routes/disable",
        "/v1/pairings/revoke",
        "/v1/pairings/register",
        "/v1/requests",
        "/v1/results",
      ].includes(path)
    )
      return directFetch(request, env);
    if (path !== "/health")
      return Response.json({ error: "not_found" }, { status: 404, headers });
    if (request.method !== "GET")
      return Response.json(
        { error: "method_not_allowed" },
        { status: 405, headers: { ...headers, Allow: "GET" } },
      );
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
