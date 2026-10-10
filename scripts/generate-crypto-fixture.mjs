// Regenerates disposable public test keys only. Never use these keys in an app.
import { mkdir, writeFile } from "node:fs/promises";
import {
  generateKeyPair,
  exportJWK,
  calculateJwkThumbprint,
  CompactSign,
  CompactEncrypt,
} from "jose";
const signing = await generateKeyPair("ES256", { extractable: true });
const encryption = await generateKeyPair("RSA-OAEP-256", {
  modulusLength: 2048,
  extractable: true,
});
const signingPrivate = await exportJWK(signing.privateKey);
const signingPublic = await exportJWK(signing.publicKey);
const encryptionPrivate = await exportJWK(encryption.privateKey);
const encryptionPublic = await exportJWK(encryption.publicKey);
const signingId = await calculateJwkThumbprint(signingPublic);
const encryptionId = await calculateJwkThumbprint(encryptionPublic);
for (const key of [signingPrivate, signingPublic]) key.kid = signingId;
for (const key of [encryptionPrivate, encryptionPublic]) key.kid = encryptionId;
const context = {
  version: 1,
  direction: "request",
  requestId: "00000000-0000-4000-8000-000000000001",
  sender: signingId,
  recipient: encryptionId,
  pairingEpoch: "00000000-0000-4000-8000-000000000002",
  issuedAt: 1700000000,
  expiresAt: 1700000300,
};
const payload = {
  source: "gmail",
  operation: "search",
  query: "invoice",
  purpose: "Find receipt",
  fields: ["subject"],
  since: 1699000000,
  until: 1700000000,
  maxResults: 5,
};
const signed = await new CompactSign(
  new TextEncoder().encode(JSON.stringify({ context, payload })),
)
  .setProtectedHeader({ alg: "ES256", typ: "agw+jws", kid: signingId })
  .sign(signing.privateKey);
const jwe = await new CompactEncrypt(new TextEncoder().encode(signed))
  .setProtectedHeader({
    alg: "RSA-OAEP-256",
    enc: "A256GCM",
    cty: "agw+jws",
    kid: encryptionId,
  })
  .encrypt(encryption.publicKey);
await mkdir("protocol/fixtures", { recursive: true });
await writeFile(
  "protocol/fixtures/crypto.json",
  JSON.stringify(
    {
      testKeysOnly: true,
      signingPrivate,
      signingPublic,
      encryptionPrivate,
      encryptionPublic,
      envelope: { context, jwe },
      payload,
    },
    null,
    2,
  ) + "\n",
);
