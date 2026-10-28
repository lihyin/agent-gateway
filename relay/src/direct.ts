import {
  CompactEncrypt,
  compactDecrypt,
  compactVerify,
  decodeJwt,
  importJWK,
  calculateJwkThumbprint,
  importPKCS8,
  SignJWT,
  type JWK,
} from "jose";
import type { DurableObjectNamespace } from "@cloudflare/workers-types";
import { boundedText, publicOrigin } from "./foreground.js";
import {
  registryPair,
  destinationOperation,
  deletePair,
  retiredPair,
  selfRegisterPair,
  type RegistryEnvironment,
} from "./registry.js";

export interface DirectEnvironment extends RegistryEnvironment {
  RELAY_ORIGIN?: string;
  RELAY_ROUTING_KEY?: string;
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
  APNS_PRIVATE_KEY?: string;
  APNS_TOPIC?: string;
  APNS_ENVIRONMENT?: string;
  CHANNELS?: DurableObjectNamespace;
}
export type Context = {
  version: 1;
  direction: "request" | "result";
  requestId: string;
  sender: string;
  recipient: string;
  pairingEpoch: string;
  issuedAt: number;
  expiresAt: number;
};
export type Envelope = { context: Context; jwe: string };
export type Pair = {
  deviceSigningKey: JWK;
  agentSigningKey: JWK;
  deviceId: string;
  agentId: string;
  pairingEpoch: string;
};
export type PairHint = { agentId?: string; deviceId?: string };
type Destination = {
  version: 1;
  audience: string;
  deviceId: string;
  agentId: string;
  pairingEpoch: string;
  pushToken: string;
};
export const seconds = () => Math.floor(Date.now() / 1000);
export function exact(
  value: unknown,
  keys: string[],
): asserts value is Record<string, unknown> {
  if (
    !value ||
    typeof value !== "object" ||
    Array.isArray(value) ||
    Object.keys(value).sort().join() !== [...keys].sort().join()
  )
    throw new Error("unauthorized");
}
// Validate a pair record (the public transportConfiguration shape) from any
// source: PairingRegistry or a device/operator provisioning
// request. Key thumbprints must match the claimed IDs.
export async function validatePairRecord(value: unknown): Promise<Pair> {
  exact(value, [
    "deviceSigningKey",
    "agentSigningKey",
    "deviceId",
    "agentId",
    "pairingEpoch",
  ]);
  const pair = value as Pair;
  if (
    typeof pair.pairingEpoch !== "string" ||
    !/^[A-Za-z0-9_-]{1,128}$/.test(pair.pairingEpoch)
  )
    throw new Error("configuration_required");
  for (const [key, id] of [
    [pair.deviceSigningKey, pair.deviceId],
    [pair.agentSigningKey, pair.agentId],
  ] as const) {
    exact(key, ["kty", "crv", "x", "y"]);
    if (
      key.kty !== "EC" ||
      key.crv !== "P-256" ||
      (await calculateJwkThumbprint(key)) !== id
    )
      throw new Error("configuration_required");
  }
  return pair;
}

export async function configuration(
  env: DirectEnvironment,
  hint: PairHint = {},
): Promise<{ pair: Pair; origin: string; key: Uint8Array }> {
  const origin = publicOrigin(env.RELAY_ORIGIN ?? "");
  const pair = await validatePairRecord(await registryPair(env, hint));
  if (!/^[A-Za-z0-9_-]{43}$/.test(env.RELAY_ROUTING_KEY ?? ""))
    throw new Error("configuration_required");
  const key = Uint8Array.from(
    atob(env.RELAY_ROUTING_KEY!.replace(/-/g, "+").replace(/_/g, "/") + "="),
    (c) => c.charCodeAt(0),
  );
  return { pair, origin, key };
}
async function proof(
  compact: string,
  key: JWK,
  type: string,
  origin: string,
  now: number,
) {
  const verified = await compactVerify(compact, await importJWK(key, "ES256"), {
    algorithms: ["ES256"],
  });
  exact(verified.protectedHeader, ["alg", "typ"]);
  if (verified.protectedHeader.typ !== type) throw new Error("unauthorized");
  const value = JSON.parse(
    new TextDecoder("utf-8", { fatal: true }).decode(verified.payload),
  );
  if (
    !value ||
    value.version !== 1 ||
    value.audience !== origin ||
    !Number.isInteger(value.issuedAt) ||
    !Number.isInteger(value.expiresAt) ||
    value.issuedAt > now ||
    value.expiresAt <= now ||
    value.expiresAt <= value.issuedAt ||
    value.expiresAt - value.issuedAt > 30
  )
    throw new Error("unauthorized");
  return value;
}
export function envelope(
  value: unknown,
  pair: Pair,
  direction: "request" | "result",
  now: number,
): Envelope {
  exact(value, ["context", "jwe"]);
  exact(value.context, [
    "version",
    "direction",
    "requestId",
    "sender",
    "recipient",
    "pairingEpoch",
    "issuedAt",
    "expiresAt",
  ]);
  const c = value.context;
  if (
    c.version !== 1 ||
    c.direction !== direction ||
    c.sender !== (direction === "request" ? pair.agentId : pair.deviceId) ||
    c.recipient !== (direction === "request" ? pair.deviceId : pair.agentId) ||
    c.pairingEpoch !== pair.pairingEpoch ||
    typeof c.requestId !== "string" ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(
      c.requestId,
    ) ||
    !Number.isInteger(c.issuedAt) ||
    !Number.isInteger(c.expiresAt) ||
    (c.issuedAt as number) > now ||
    (c.expiresAt as number) <= now ||
    (c.expiresAt as number) <= (c.issuedAt as number) ||
    (c.expiresAt as number) - (c.issuedAt as number) > 300 ||
    typeof value.jwe !== "string" ||
    !/^[A-Za-z0-9_.-]+$/.test(value.jwe)
  )
    throw new Error("unauthorized");
  if (
    new TextEncoder().encode(JSON.stringify(value)).length >
    (direction === "request" ? 3500 : 65536)
  )
    throw new Error("oversize");
  return value as unknown as Envelope;
}
// Lookup hints are read from the UNVERIFIED token. They only choose which
// pair record to load; proof() then verifies the signature against that
// record's keys and every existing equality check still runs.
function registerHint(compact: string): PairHint {
  try {
    const payload = decodeJwt(compact);
    return {
      agentId:
        typeof payload.agentId === "string" ? payload.agentId : undefined,
      deviceId:
        typeof payload.deviceId === "string" ? payload.deviceId : undefined,
    };
  } catch {
    return {};
  }
}
function envelopeHint(
  compact: string,
  field: "agentId" | "deviceId",
): PairHint {
  try {
    const payload = decodeJwt(compact) as {
      envelope?: { context?: { sender?: unknown } };
    };
    const sender = payload.envelope?.context?.sender;
    return typeof sender === "string" ? { [field]: sender } : {};
  } catch {
    return {};
  }
}
export async function issueRoute(
  compact: string,
  env: DirectEnvironment,
  now = seconds(),
) {
  const { pair, origin, key } = await configuration(env, registerHint(compact));
  const value = await proof(
    compact,
    pair.deviceSigningKey,
    "agw+register",
    origin,
    now,
  );
  exact(value, [
    "version",
    "audience",
    "deviceId",
    "agentId",
    "pairingEpoch",
    "pushToken",
    "updatedAt",
    "issuedAt",
    "expiresAt",
  ]);
  if (
    value.deviceId !== pair.deviceId ||
    value.agentId !== pair.agentId ||
    value.pairingEpoch !== pair.pairingEpoch ||
    !Number.isSafeInteger(value.updatedAt) ||
    Number(value.updatedAt) < Number(value.issuedAt) * 1000 ||
    Number(value.updatedAt) >= (now + 1) * 1000 ||
    typeof value.pushToken !== "string" ||
    !/^[0-9a-f]{64,200}$/.test(value.pushToken)
  )
    throw new Error("unauthorized");
  const route = {
    version: 1,
    audience: origin,
    deviceId: pair.deviceId,
    agentId: pair.agentId,
    pairingEpoch: pair.pairingEpoch,
    pushToken: value.pushToken,
  };
  const token = await new CompactEncrypt(
    new TextEncoder().encode(JSON.stringify(route)),
  )
    .setProtectedHeader({ alg: "dir", enc: "A256GCM", typ: "agw+route" })
    .encrypt(key);
  await destinationOperation(env, {
    pair,
    action: "register",
    sealed: token,
    issuedAt: Number(value.updatedAt),
    now,
  });
  return { status: "registered" };
}
export async function verifyRequest(
  compact: string,
  env: DirectEnvironment,
  now = seconds(),
) {
  const { pair, origin, key } = await configuration(
    env,
    envelopeHint(compact, "agentId"),
  );
  const value = await proof(
    compact,
    pair.agentSigningKey,
    "agw+request",
    origin,
    now,
  );
  exact(value, ["version", "audience", "issuedAt", "expiresAt", "envelope"]);
  const request = envelope(value.envelope, pair, "request", now);
  const destination = await destinationOperation(env, {
    pair,
    action: "resolve",
    now,
  });
  const decoded = await compactDecrypt(destination.sealed!, key, {
    keyManagementAlgorithms: ["dir"],
    contentEncryptionAlgorithms: ["A256GCM"],
  });
  exact(decoded.protectedHeader, ["alg", "enc", "typ"]);
  const route = JSON.parse(
    new TextDecoder().decode(decoded.plaintext),
  ) as Destination;
  exact(route, [
    "version",
    "audience",
    "deviceId",
    "agentId",
    "pairingEpoch",
    "pushToken",
  ]);
  if (
    decoded.protectedHeader.typ !== "agw+route" ||
    route.version !== 1 ||
    route.audience !== origin ||
    route.deviceId !== pair.deviceId ||
    route.agentId !== pair.agentId ||
    route.pairingEpoch !== pair.pairingEpoch
  )
    throw new Error("unauthorized");
  return {
    envelope: request,
    pushToken: route.pushToken,
  };
}
export async function verifyResult(
  compact: string,
  env: DirectEnvironment,
  now = seconds(),
) {
  const { pair, origin } = await configuration(
    env,
    envelopeHint(compact, "deviceId"),
  );
  const value = await proof(
    compact,
    pair.deviceSigningKey,
    "agw+result",
    origin,
    now,
  );
  exact(value, ["version", "audience", "issuedAt", "expiresAt", "envelope"]);
  return envelope(value.envelope, pair, "result", now);
}
export async function push(
  env: DirectEnvironment,
  pushToken: string,
  request: Envelope,
): Promise<void> {
  if (
    !env.APNS_KEY_ID ||
    !env.APNS_TEAM_ID ||
    !env.APNS_PRIVATE_KEY ||
    env.APNS_TOPIC !== "com.agentbrain.agentgateway" ||
    !["production", "sandbox"].includes(env.APNS_ENVIRONMENT ?? "")
  )
    throw new Error("transport_unavailable");
  const payload = JSON.stringify({
    aps: {
      alert: { title: "Agent Gateway", body: "A request is ready for review." },
      sound: "default",
    },
    agw: request,
  });
  if (new TextEncoder().encode(payload).length > 4096)
    throw new Error("oversize");
  const token = await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: env.APNS_KEY_ID })
    .setIssuer(env.APNS_TEAM_ID)
    .setIssuedAt()
    .sign(await importPKCS8(env.APNS_PRIVATE_KEY, "ES256"));
  const host =
    env.APNS_ENVIRONMENT === "sandbox"
      ? "api.sandbox.push.apple.com"
      : "api.push.apple.com";
  const response = await fetch(`https://${host}/3/device/${pushToken}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${token}`,
      "apns-topic": env.APNS_TOPIC,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "apns-expiration": String(request.context.expiresAt),
      "content-type": "application/json",
    },
    body: payload,
    redirect: "manual",
    signal: AbortSignal.timeout(10000),
  });
  await response.body?.cancel();
  if (!response.ok) throw new Error("transport_unavailable");
}
export async function directFetch(
  request: Request,
  env: DirectEnvironment,
): Promise<Response> {
  const headers = {
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
  };
  const url = new URL(request.url);
  if (
    !env.RELAY_ORIGIN ||
    !env.PAIRINGS_REGISTRY ||
    !env.RELAY_ROUTING_KEY ||
    !env.CHANNELS
  )
    return Response.json({ error: "not_found" }, { status: 404, headers });
  try {
    if (
      url.origin !== publicOrigin(env.RELAY_ORIGIN) ||
      url.search ||
      request.headers.has("Origin")
    )
      throw new Error("unauthorized");
    if (url.pathname === "/v1/requests") {
      if (
        request.method !== "GET" ||
        request.headers.get("Upgrade")?.toLowerCase() !== "websocket"
      )
        return Response.json(
          { error: "websocket_required" },
          { status: 426, headers },
        );
      const auth = request.headers.get("Authorization") ?? "";
      if (!auth.startsWith("Bearer ") || auth.length > 16000)
        throw new Error("unauthorized");
      const input = await verifyRequest(auth.slice(7), env);
      const id = env.CHANNELS.idFromName(
        `${input.envelope.context.sender}:${input.envelope.context.recipient}:${input.envelope.context.pairingEpoch}:${input.envelope.context.requestId}`,
      );
      return (await env.CHANNELS.get(id).fetch("https://channel/open", {
        headers: {
          Upgrade: "websocket",
          "X-Gateway-Input": JSON.stringify(input),
        },
      })) as unknown as Response;
    }
    if (
      request.method !== "POST" ||
      request.headers.get("Content-Type") !==
        (url.pathname === "/v1/pairings/register"
          ? "application/json"
          : "application/jose")
    )
      return Response.json(
        { error: "invalid_request" },
        { status: 400, headers },
      );
    const compact = await boundedText(request, 92000);
    if (url.pathname === "/v1/pairings/register") {
      await selfRegisterPair(
        env,
        JSON.parse(compact),
        publicOrigin(env.RELAY_ORIGIN),
      );
      return Response.json({ status: "registered" }, { headers });
    }
    if (url.pathname === "/v1/routes")
      return Response.json(await issueRoute(compact, env), { headers });
    if (["/v1/routes/disable", "/v1/pairings/revoke"].includes(url.pathname)) {
      const hint = decodeJwt(compact);
      const origin = publicOrigin(env.RELAY_ORIGIN!);
      const current = await registryPair(env, registerHint(compact));
      const pair = await validatePairRecord(
        current?.pairingEpoch === hint.pairingEpoch
          ? current
          : url.pathname === "/v1/pairings/revoke" &&
              typeof hint.deviceId === "string" &&
              typeof hint.pairingEpoch === "string"
            ? await retiredPair(env, hint.deviceId, hint.pairingEpoch)
            : undefined,
      );
      const value = await proof(
        compact,
        pair.deviceSigningKey,
        url.pathname === "/v1/routes/disable"
          ? "agw+route-disable"
          : "agw+unpair",
        origin,
        seconds(),
      );
      exact(value, [
        "version",
        "audience",
        "deviceId",
        "agentId",
        "pairingEpoch",
        "issuedAt",
        "expiresAt",
        "updatedAt",
      ]);
      if (
        !Number.isSafeInteger(value.updatedAt) ||
        Number(value.updatedAt) < Number(value.issuedAt) * 1000 ||
        Number(value.updatedAt) >= (seconds() + 1) * 1000 ||
        value.deviceId !== pair.deviceId ||
        value.agentId !== pair.agentId ||
        value.pairingEpoch !== pair.pairingEpoch
      )
        throw new Error("unauthorized");
      if (url.pathname === "/v1/pairings/revoke") await deletePair(env, pair);
      else
        await destinationOperation(env, {
          pair,
          action: "disable",
          issuedAt: Number(value.updatedAt),
          now: seconds(),
        });
      return Response.json({ status: "revoked" }, { headers });
    }
    const result = await verifyResult(compact, env);
    const id = env.CHANNELS.idFromName(
      `${result.context.recipient}:${result.context.sender}:${result.context.pairingEpoch}:${result.context.requestId}`,
    );
    return (await env.CHANNELS.get(id).fetch("https://channel/result", {
      method: "POST",
      body: JSON.stringify(result),
    })) as unknown as Response;
  } catch (error) {
    const code = error instanceof Error ? error.message : "unauthorized";
    const status =
      code === "rate_limited"
        ? 429
        : code === "oversize"
          ? 413
          : code === "transport_unavailable" ||
              code === "configuration_required"
            ? 503
            : 401;
    return Response.json(
      {
        error:
          status === 429
            ? "rate_limited"
            : status === 413
              ? "oversize"
              : status === 503
                ? "transport_unavailable"
                : "unauthorized",
      },
      { status, headers },
    );
  }
}
