import type {
  DurableObjectNamespace,
  DurableObjectState,
} from "@cloudflare/workers-types";
import { compactVerify, importJWK } from "jose";
import { exact, validatePairRecord, type Pair } from "./direct.js";

// Durable authority for pairing identities and encrypted push destinations.
// Request/result payloads and private endpoint keys never enter this registry.
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
      this.ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS destinations (
        device_id TEXT PRIMARY KEY, epoch TEXT NOT NULL, sealed TEXT NOT NULL,
        issued_at INTEGER NOT NULL, window INTEGER NOT NULL DEFAULT 0,
        attempts INTEGER NOT NULL DEFAULT 0)`);
      this.ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS retired_epochs (
        device_id TEXT NOT NULL, epoch TEXT NOT NULL, record TEXT NOT NULL, PRIMARY KEY(device_id, epoch))`);
    });
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/retired" && request.method === "GET") {
      const rows = this.ctx.storage.sql
        .exec(
          "SELECT record FROM retired_epochs WHERE device_id = ? AND epoch = ?",
          url.searchParams.get("deviceId") ?? "",
          url.searchParams.get("epoch") ?? "",
        )
        .toArray();
      return rows.length
        ? Response.json(JSON.parse(rows[0].record as string))
        : new Response(null, { status: 404 });
    }
    if (url.pathname === "/revoke" && request.method === "POST") {
      const pair = (await request.json()) as Pair;
      const rows = this.ctx.storage.sql
        .exec(`SELECT record FROM pairs WHERE device_id = ?`, pair.deviceId)
        .toArray();
      if (!rows.length || rows[0].record !== JSON.stringify(pair)) {
        const retired = this.ctx.storage.sql
          .exec(
            "SELECT record FROM retired_epochs WHERE device_id = ? AND epoch = ?",
            pair.deviceId,
            pair.pairingEpoch,
          )
          .toArray();
        return retired.length && retired[0].record === JSON.stringify(pair)
          ? Response.json({ status: "revoked" })
          : new Response(null, { status: 401 });
      }
      this.ctx.storage.sql.exec(
        `INSERT OR IGNORE INTO retired_epochs VALUES (?, ?, ?)`,
        pair.deviceId,
        pair.pairingEpoch,
        JSON.stringify(pair),
      );
      this.ctx.storage.sql.exec(
        `DELETE FROM destinations WHERE device_id = ?`,
        pair.deviceId,
      );
      this.ctx.storage.sql.exec(
        `DELETE FROM pairs WHERE device_id = ?`,
        pair.deviceId,
      );
      return Response.json({ status: "revoked" });
    }
    if (url.pathname === "/pair" && request.method === "PUT") {
      // Body is a pair record already validated by the caller
      // (provisioningFetch / selfRegisterPair) via validatePairRecord.
      // A re-pair must replace the pair's previous record even when the
      // agent identity changed too, so clear any row for this agent or
      // device before inserting (device_id is UNIQUE).
      const pair = (await request.json()) as Pair;
      const retired = this.ctx.storage.sql
        .exec(
          `SELECT epoch FROM retired_epochs WHERE device_id = ? AND epoch = ?`,
          pair.deviceId,
          pair.pairingEpoch,
        )
        .toArray();
      if (retired.length) return new Response(null, { status: 409 });
      const existing = this.ctx.storage.sql
        .exec(
          `SELECT record FROM pairs WHERE agent_id = ? OR device_id = ?`,
          pair.agentId,
          pair.deviceId,
        )
        .toArray()
        .map((row) => JSON.parse(row.record as string) as Pair);
      if (existing.some((old) => old.deviceId !== pair.deviceId))
        return new Response(null, { status: 409 });
      for (const old of existing) {
        if (old.pairingEpoch === pair.pairingEpoch) {
          if (JSON.stringify(old) !== JSON.stringify(pair))
            return new Response(null, { status: 409 });
          continue;
        }
        this.ctx.storage.sql.exec(
          `INSERT OR IGNORE INTO retired_epochs VALUES (?, ?, ?)`,
          old.deviceId,
          old.pairingEpoch,
          JSON.stringify(old),
        );
        this.ctx.storage.sql.exec(
          `DELETE FROM destinations WHERE device_id = ?`,
          old.deviceId,
        );
      }
      this.ctx.storage.sql.exec(
        `DELETE FROM pairs WHERE agent_id = ? OR device_id = ?`,
        pair.agentId,
        pair.deviceId,
      );
      this.ctx.storage.sql.exec(
        `INSERT INTO pairs (agent_id, device_id, record, updated_at)
         VALUES (?, ?, ?, ?)`,
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
      const old = this.ctx.storage.sql
        .exec(`SELECT record FROM pairs WHERE agent_id = ?`, agentId)
        .toArray();
      for (const row of old) {
        const pair = JSON.parse(row.record as string) as Pair;
        this.ctx.storage.sql.exec(
          `INSERT OR IGNORE INTO retired_epochs VALUES (?, ?, ?)`,
          pair.deviceId,
          pair.pairingEpoch,
          JSON.stringify(pair),
        );
        this.ctx.storage.sql.exec(
          `DELETE FROM destinations WHERE device_id = ?`,
          pair.deviceId,
        );
      }
      this.ctx.storage.sql.exec(
        `DELETE FROM pairs WHERE agent_id = ?`,
        agentId,
      );
      return Response.json({ status: "deleted" });
    }
    if (url.pathname === "/destination" && request.method === "POST") {
      const input = (await request.json()) as {
        pair: Pair;
        action: "register" | "resolve" | "disable";
        sealed?: string;
        issuedAt?: number;
        now: number;
      };
      const rows = this.ctx.storage.sql
        .exec(
          `SELECT record FROM pairs WHERE device_id = ?`,
          input.pair.deviceId,
        )
        .toArray();
      if (!rows.length || rows[0].record !== JSON.stringify(input.pair))
        return new Response(null, { status: 401 });
      const current = this.ctx.storage.sql
        .exec(
          `SELECT * FROM destinations WHERE device_id = ?`,
          input.pair.deviceId,
        )
        .toArray()[0];
      if (input.action === "resolve") {
        if (!current || !current.sealed)
          return new Response(null, { status: 503 });
        const window = Math.floor(input.now / 60);
        const attempts =
          current.window === window ? Number(current.attempts) : 0;
        if (attempts >= 10) return new Response(null, { status: 429 });
        this.ctx.storage.sql.exec(
          `UPDATE destinations SET window = ?, attempts = ? WHERE device_id = ?`,
          window,
          attempts + 1,
          input.pair.deviceId,
        );
        return Response.json({ sealed: current.sealed });
      }
      if (current && Number(current.issued_at) >= input.issuedAt!)
        return new Response(null, { status: 409 });
      this.ctx.storage.sql.exec(
        `INSERT INTO destinations(device_id, epoch, sealed, issued_at)
        VALUES (?, ?, ?, ?) ON CONFLICT(device_id) DO UPDATE SET epoch=excluded.epoch, sealed=excluded.sealed, issued_at=excluded.issued_at`,
        input.pair.deviceId,
        input.pair.pairingEpoch,
        input.action === "disable" ? "" : input.sealed!,
        input.issuedAt!,
      );
      return Response.json({ status: "registered" });
    }
    return Response.json({ error: "not_found" }, { status: 404 });
  }
}

export async function destinationOperation(
  env: RegistryEnvironment,
  input: {
    pair: Pair;
    action: "register" | "resolve" | "disable";
    sealed?: string;
    issuedAt?: number;
    now: number;
  },
): Promise<{ sealed?: string }> {
  const response = await registryStub(env)!.fetch(
    "https://registry/destination",
    {
      method: "POST",
      body: JSON.stringify(input),
    },
  );
  if (!response.ok)
    throw new Error(
      response.status === 429
        ? "rate_limited"
        : response.status === 503
          ? "transport_unavailable"
          : "unauthorized",
    );
  return (await response.json()) as { sealed?: string };
}

export async function deletePair(
  env: RegistryEnvironment,
  pair: Pair,
): Promise<void> {
  // Compare in the same DO turn before deletion, so an old epoch cannot revoke a new pair.
  const response = await registryStub(env)!.fetch(`https://registry/revoke`, {
    method: "POST",
    body: JSON.stringify(pair),
  });
  if (!response.ok) throw new Error("unauthorized");
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

// Store a pair record that the caller has already validated. The registry
// keys rows by agentId and enforces one row per deviceId, so storing a
// re-pair replaces that pair's previous epoch atomically.
export async function storePairRecord(
  env: RegistryEnvironment,
  pair: Pair,
): Promise<boolean> {
  const stub = registryStub(env);
  if (!stub) return false;
  const stored = await stub.fetch("https://registry/pair", {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(pair),
  });
  return stored.ok;
}

// Self-registration (provisioning decision, 2026-10-18 — see
// docs/pairing-registry.md): during a live pairing the phone sends one extra
// cleartext frame on its pairing socket,
//   { kind: "pairing_record", record: <transportConfiguration>, proof: <JWS> }
// where proof is an ES256 JWS (typ "agw+pair-register") signed with the
// DEVICE signing key from the record itself, over exactly
//   { version: 1, audience, deviceId, agentId, pairingEpoch, issuedAt,
//     expiresAt }.
// The device is the trust root of a pairing: its signature over the record's
// IDs and epoch attests "this agent is paired with me". Validating the
// record first (exact shape, JWK thumbprints == claimed IDs) binds the
// proof key to the claimed deviceId, so registering a rogue agent for
// someone else's device would require that device's private key.
// Registering your own pair is the intended multi-user flow, so no operator
// secret is involved. issuedAt may lead the relay clock by up to 30s (the
// same peer clock-skew allowance the agent applies to pairing receipts);
// the proof window is at most 300s, matching the pairing session lifetime.
export async function verifySelfRegistration(
  frame: unknown,
  audience: string,
  now = Math.floor(Date.now() / 1000),
): Promise<Pair> {
  exact(frame, ["kind", "record", "proof"]);
  const { kind, record, proof } = frame as {
    kind: unknown;
    record: unknown;
    proof: unknown;
  };
  if (kind !== "pairing_record" || typeof proof !== "string")
    throw new Error("unauthorized");
  const pair = await validatePairRecord(record);
  const verified = await compactVerify(
    proof,
    await importJWK(pair.deviceSigningKey, "ES256"),
    { algorithms: ["ES256"] },
  );
  exact(verified.protectedHeader, ["alg", "typ"]);
  if (verified.protectedHeader.typ !== "agw+pair-register")
    throw new Error("unauthorized");
  const value = JSON.parse(
    new TextDecoder("utf-8", { fatal: true }).decode(verified.payload),
  );
  exact(value, [
    "version",
    "audience",
    "deviceId",
    "agentId",
    "pairingEpoch",
    "issuedAt",
    "expiresAt",
  ]);
  if (
    value.version !== 1 ||
    value.audience !== audience ||
    value.deviceId !== pair.deviceId ||
    value.agentId !== pair.agentId ||
    value.pairingEpoch !== pair.pairingEpoch ||
    !Number.isInteger(value.issuedAt) ||
    !Number.isInteger(value.expiresAt) ||
    (value.issuedAt as number) > now + 30 ||
    (value.expiresAt as number) <= now ||
    (value.expiresAt as number) <= (value.issuedAt as number) ||
    (value.expiresAt as number) - (value.issuedAt as number) > 300
  )
    throw new Error("unauthorized");
  return pair;
}

// Verify a self-registration frame and store its record. Without the registry
// no transport authority exists; validation/storage failures close the session.
export async function selfRegisterPair(
  env: RegistryEnvironment,
  frame: unknown,
  audience: string,
): Promise<boolean> {
  if (!env.PAIRINGS_REGISTRY) throw new Error("configuration_required");
  const stored = await storePairRecord(
    env,
    await verifySelfRegistration(frame, audience),
  );
  if (!stored) throw new Error("unauthorized");
  return true;
}

// Operator provisioning path (bootstrap / recovery — see
// docs/pairing-registry.md): POST /v1/pairings with
// `Authorization: Bearer <PROVISIONING_SECRET>` and a pair record (the public
// transportConfiguration JSON) as the body. Stores or replaces that
// agentId's record, so a re-pair is a single call instead of a secret edit +
// redeploy. Disabled (404) unless PROVISIONING_SECRET is set.
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
  const ok = await storePairRecord(env, pair);
  return Response.json(
    { status: ok ? "stored" : "not_found" },
    { status: ok ? 200 : 404, headers },
  );
}

// Retired records are available only for authenticating idempotent revocation,
// never as a transport authorization fallback.
export async function retiredPair(
  env: RegistryEnvironment,
  deviceId: string,
  epoch: string,
): Promise<Pair | undefined> {
  const response = await registryStub(env)!.fetch(
    "https://registry/retired?" + new URLSearchParams({ deviceId, epoch }),
  );
  return response.ok ? ((await response.json()) as Pair) : undefined;
}
