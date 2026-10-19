import type {
  DurableObjectNamespace,
  DurableObjectState,
} from "@cloudflare/workers-types";
import { validatePairRecord, type Pair } from "./direct.js";

// DESIGN SKETCH (draft PR — not yet wired into production configuration):
// Multi-pair storage for the relay, replacing the single-pair PAIRING_CONFIG
// secret. Records are public material only (signing public keys + IDs +
// pairing epoch) — the exact object shape PAIRING_CONFIG holds today.
//
// Why a Durable Object: the relay already runs on DOs (CHANNELS, PAIRINGS),
// and DO SQLite storage is strongly consistent, so a re-pair (new epoch) is
// effective immediately — no KV propagation window where a freshly re-paired
// user is still rejected. One global instance is enough: pair records are
// tiny and reads are single-row lookups keyed by agentId or deviceId.

export interface RegistryEnvironment {
  PAIRINGS_REGISTRY?: DurableObjectNamespace;
  PROVISIONING_SECRET?: string;
}

const REGISTRY_NAME = "global";

export class PairingRegistry {
  constructor(private readonly ctx: DurableObjectState) {
    this.ctx.blockConcurrencyWhile(async () => {
      this.ctx.storage.sql.exec(
        `CREATE TABLE IF NOT EXISTS pairs (
           agent_id TEXT PRIMARY KEY,
           device_id TEXT NOT NULL UNIQUE,
           record TEXT NOT NULL,
           updated_at INTEGER NOT NULL
         )`,
      );
    });
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/pair" && request.method === "PUT") {
      // Body is a pair record already validated by the caller
      // (provisioningFetch) via validatePairRecord.
      const pair = (await request.json()) as Pair;
      this.ctx.storage.sql.exec(
        `INSERT INTO pairs (agent_id, device_id, record, updated_at)
         VALUES (?, ?, ?, ?)
         ON CONFLICT(agent_id) DO UPDATE SET
           device_id = excluded.device_id,
           record = excluded.record,
           updated_at = excluded.updated_at`,
        pair.agentId,
        pair.deviceId,
        JSON.stringify(pair),
        Date.now(),
      );
      return Response.json({ status: "stored" });
    }
    if (url.pathname === "/pair" && request.method === "GET") {
      const agentId = url.searchParams.get("agentId");
      const deviceId = url.searchParams.get("deviceId");
      const rows = this.ctx.storage.sql
        .exec(
          `SELECT record FROM pairs WHERE agent_id = ? OR device_id = ? LIMIT 1`,
          agentId ?? "",
          deviceId ?? "",
        )
        .toArray();
      if (rows.length === 0)
        return Response.json({ error: "not_found" }, { status: 404 });
      return new Response(rows[0].record as string, {
        headers: { "Content-Type": "application/json" },
      });
    }
    if (url.pathname === "/pair" && request.method === "DELETE") {
      const agentId = url.searchParams.get("agentId") ?? "";
      this.ctx.storage.sql.exec(
        `DELETE FROM pairs WHERE agent_id = ?`,
        agentId,
      );
      return Response.json({ status: "deleted" });
    }
    return Response.json({ error: "not_found" }, { status: 404 });
  }
}

function registryStub(env: RegistryEnvironment) {
  if (!env.PAIRINGS_REGISTRY) return undefined;
  return env.PAIRINGS_REGISTRY.get(
    env.PAIRINGS_REGISTRY.idFromName(REGISTRY_NAME),
  );
}

// Look up a pair record by unverified hint IDs taken from the request token.
// The hint is ONLY a lookup key: callers still verify the token signature
// against the returned pair's keys and run every existing equality check, so
// a forged hint can at most select the wrong record and fail verification.
export async function registryPair(
  env: RegistryEnvironment,
  hint: { agentId?: string; deviceId?: string },
): Promise<Pair | undefined> {
  const stub = registryStub(env);
  if (!stub || (!hint.agentId && !hint.deviceId)) return undefined;
  const query = new URLSearchParams();
  if (hint.agentId) query.set("agentId", hint.agentId);
  if (hint.deviceId) query.set("deviceId", hint.deviceId);
  const response = await stub.fetch(`https://registry/pair?${query}`);
  if (!response.ok) return undefined;
  return (await response.json()) as Pair;
}

// Provisioning path (open design question — see docs/pairing-registry.md):
// POST /v1/pairings with `Authorization: Bearer <PROVISIONING_SECRET>` and a
// pair record (the public transportConfiguration JSON) as the body. Stores or
// replaces that agentId's record, so a re-pair is a single call instead of a
// secret edit + redeploy. Disabled (404) unless PROVISIONING_SECRET is set.
export async function provisioningFetch(
  request: Request,
  env: RegistryEnvironment,
): Promise<Response> {
  const headers = { "Cache-Control": "no-store" };
  const stub = registryStub(env);
  if (!stub || !env.PROVISIONING_SECRET)
    return Response.json({ error: "not_found" }, { status: 404, headers });
  if (
    request.headers.get("Authorization") !== `Bearer ${env.PROVISIONING_SECRET}`
  )
    return Response.json({ error: "unauthorized" }, { status: 401, headers });
  let pair: Pair;
  try {
    pair = await validatePairRecord(await request.json());
  } catch {
    return Response.json(
      { error: "invalid_request" },
      { status: 400, headers },
    );
  }
  const stored = await stub.fetch("https://registry/pair", {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(pair),
  });
  return Response.json(await stored.json(), { status: stored.status, headers });
}
