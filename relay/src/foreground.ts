import {
  compactVerify,
  importJWK,
  calculateJwkThumbprint,
  type JWK,
} from "jose";

export type PairingConfiguration = {
  deviceSigningKey: JWK;
  deviceId: string;
  agentId: string;
  pairingEpoch: string;
};
export type SyncProof = {
  version: 1;
  audience: string;
  deviceId: string;
  agentId: string;
  pairingEpoch: string;
  issuedAt: number;
  expiresAt: number;
  knownRequests: string[];
  result: unknown;
};
const uuid =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
export function publicOrigin(value: string): string {
  const url = new URL(value);
  if (
    url.protocol !== "https:" ||
    url.origin !== value ||
    url.username ||
    url.password ||
    url.port ||
    !/^[a-z][a-z0-9.-]+\.[a-z]{2,}$/i.test(url.hostname) ||
    /\.(local|internal|localhost|test|invalid)$/i.test(url.hostname)
  )
    throw new Error("configuration_required");
  return url.origin;
}
export async function boundedText(
  response: Request | Response,
  limit: number,
): Promise<string> {
  if (Number(response.headers.get("content-length")) > limit)
    throw new Error("oversize");
  const reader = response.body?.getReader();
  if (!reader) throw new Error("invalid_request");
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > limit) throw new Error("oversize");
      chunks.push(value);
    }
  } finally {
    await reader.cancel();
  }
  const joined = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    joined.set(chunk, offset);
    offset += chunk.length;
  }
  return new TextDecoder("utf-8", { fatal: true }).decode(joined);
}
export async function verifySyncProof(
  compact: string,
  pair: PairingConfiguration,
  audience: string,
  now = Math.floor(Date.now() / 1000),
): Promise<SyncProof> {
  const key = pair.deviceSigningKey;
  if (
    key.kty !== "EC" ||
    key.crv !== "P-256" ||
    key.d ||
    (await calculateJwkThumbprint(key)) !== pair.deviceId
  )
    throw new Error("unauthorized");
  const verified = await compactVerify(compact, await importJWK(key, "ES256"), {
    algorithms: ["ES256"],
  });
  const header = verified.protectedHeader;
  if (
    Object.keys(header).length !== 2 ||
    header.alg !== "ES256" ||
    header.typ !== "agw+sync"
  )
    throw new Error("unauthorized");
  const proof = JSON.parse(
    new TextDecoder().decode(verified.payload),
  ) as SyncProof;
  const expected = [
    "version",
    "audience",
    "deviceId",
    "agentId",
    "pairingEpoch",
    "issuedAt",
    "expiresAt",
    "knownRequests",
    "result",
  ];
  if (
    Object.keys(proof).length !== expected.length ||
    expected.some((k) => !(k in proof)) ||
    proof.version !== 1 ||
    proof.audience !== audience ||
    proof.deviceId !== pair.deviceId ||
    proof.agentId !== pair.agentId ||
    proof.pairingEpoch !== pair.pairingEpoch ||
    !Number.isInteger(proof.issuedAt) ||
    !Number.isInteger(proof.expiresAt) ||
    proof.issuedAt > now ||
    proof.expiresAt <= now ||
    proof.expiresAt <= proof.issuedAt ||
    proof.expiresAt - proof.issuedAt > 30 ||
    !Array.isArray(proof.knownRequests) ||
    proof.knownRequests.length > 20 ||
    proof.knownRequests.some((id) => typeof id !== "string" || !uuid.test(id))
  )
    throw new Error("unauthorized");
  return proof;
}
