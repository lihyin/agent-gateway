import { createHash, randomUUID } from "node:crypto";
import {
  calculateJwkThumbprint,
  CompactEncrypt,
  compactDecrypt,
  exportJWK,
  generateKeyPair,
  importJWK,
  SignJWT,
  compactVerify,
  type JWK,
} from "jose";
import { validateProtocol } from "./protocol.js";

export type Identity = { signing: JWK; encryption: JWK };
export type PublicIdentity = Identity;
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
export function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value !== null && typeof value === "object")
    return `{${Object.entries(value)
      .sort(([a], [b]) => a.localeCompare(b, "en"))
      .map(([k, v]) => `${JSON.stringify(k)}:${canonical(v)}`)
      .join(",")}}`;
  return JSON.stringify(value);
}
export function publicIdentity(identity: Identity): PublicIdentity {
  return {
    signing: {
      kty: "EC",
      crv: "P-256",
      x: identity.signing.x,
      y: identity.signing.y,
    },
    encryption: {
      kty: "RSA",
      n: identity.encryption.n,
      e: identity.encryption.e,
    },
  };
}
export function fingerprint(identity: PublicIdentity): string {
  return createHash("sha256").update(canonical(identity)).digest("hex");
}
export async function identityId(identity: Identity): Promise<string> {
  return calculateJwkThumbprint(identity.signing);
}
export async function generateIdentity(): Promise<Identity> {
  const signing = await generateKeyPair("ES256", { extractable: true });
  const encryption = await generateKeyPair("RSA-OAEP-256", {
    modulusLength: 2048,
    extractable: true,
  });
  return {
    signing: await exportJWK(signing.privateKey),
    encryption: await exportJWK(encryption.privateKey),
  };
}
export async function signObject(
  identity: Identity,
  value: Record<string, unknown>,
  type: string,
): Promise<string> {
  return new SignJWT(value)
    .setProtectedHeader({ alg: "ES256", typ: type })
    .sign(await importJWK(identity.signing, "ES256"));
}
export async function verifyObject(
  publicKey: JWK,
  compact: string,
  type: string,
): Promise<Record<string, unknown>> {
  const result = await compactVerify(
    compact,
    await importJWK(publicKey, "ES256"),
    { algorithms: ["ES256"] },
  );
  if (
    canonical(result.protectedHeader) !== canonical({ alg: "ES256", typ: type })
  )
    throw new Error("invalid_request");
  return JSON.parse(new TextDecoder().decode(result.payload));
}
export async function encrypt(
  identity: Identity,
  recipient: Identity,
  context: Context,
  payload: Record<string, unknown>,
): Promise<Envelope> {
  validateProtocol("context", context, context.issuedAt);
  validateProtocol(
    context.direction === "request" ? "request" : "result",
    payload,
    context.issuedAt,
  );
  const signed = await signObject(identity, { context, payload }, "agw+jws");
  const jwe = await new CompactEncrypt(new TextEncoder().encode(signed))
    .setProtectedHeader({ alg: "RSA-OAEP-256", enc: "A256GCM", cty: "agw+jws" })
    .encrypt(await importJWK(recipient.encryption, "RSA-OAEP-256"));
  const envelope = { context, jwe };
  validateProtocol("envelope", envelope, context.issuedAt);
  return envelope;
}
export async function decrypt(
  identity: Identity,
  sender: Identity,
  envelope: Envelope,
  expected: Context,
  now: number,
): Promise<Record<string, unknown>> {
  validateProtocol("envelope", envelope, now);
  if (canonical(envelope.context) !== canonical(expected))
    throw new Error("invalid_request");
  const result = await compactDecrypt(
    envelope.jwe,
    await importJWK(identity.encryption, "RSA-OAEP-256"),
    {
      keyManagementAlgorithms: ["RSA-OAEP-256"],
      contentEncryptionAlgorithms: ["A256GCM"],
    },
  );
  if (
    canonical(result.protectedHeader) !==
    canonical({ alg: "RSA-OAEP-256", enc: "A256GCM", cty: "agw+jws" })
  )
    throw new Error("invalid_request");
  const signed = await verifyObject(
    sender.signing,
    new TextDecoder().decode(result.plaintext),
    "agw+jws",
  );
  if (
    canonical(Object.keys(signed).sort()) !==
      canonical(["context", "payload"]) ||
    canonical(signed.context) !== canonical(expected)
  )
    throw new Error("invalid_request");
  validateProtocol(
    expected.direction === "request" ? "request" : "result",
    signed.payload,
    now,
  );
  return signed.payload as Record<string, unknown>;
}
export function pairingOffer(identity: Identity, now: number): Promise<string> {
  return signObject(
    identity,
    {
      version: 1,
      kind: "offer",
      nonce: randomUUID(),
      identity: publicIdentity(identity),
      issuedAt: now,
      expiresAt: now + 300,
    },
    "agw+pairing",
  );
}
