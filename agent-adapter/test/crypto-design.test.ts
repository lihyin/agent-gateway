import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import {
  compactDecrypt,
  compactVerify,
  importJWK,
  generateKeyPair,
} from "jose";
import { validateProtocol } from "../src/protocol.js";
const fixture = JSON.parse(
  readFileSync(
    new URL("../../protocol/fixtures/crypto.json", import.meta.url),
    "utf8",
  ),
);
test("standard JOSE fixture verifies authenticated payload and schema", async () => {
  const encrypted = await compactDecrypt(
    fixture.envelope.jwe,
    await importJWK(fixture.encryptionPrivate, "RSA-OAEP-256"),
    {
      keyManagementAlgorithms: ["RSA-OAEP-256"],
      contentEncryptionAlgorithms: ["A256GCM"],
    },
  );
  const signed = await compactVerify(
    encrypted.plaintext,
    await importJWK(fixture.signingPublic, "ES256"),
    { algorithms: ["ES256"] },
  );
  const decoded = JSON.parse(new TextDecoder().decode(signed.payload));
  assert.deepEqual(decoded.context, fixture.envelope.context);
  validateProtocol("envelope", fixture.envelope, 1700000000);
  validateProtocol("request", decoded.payload, 1700000000);
  assert.equal(encrypted.protectedHeader.kid, fixture.encryptionPublic.kid);
  assert.equal(signed.protectedHeader.kid, fixture.signingPublic.kid);
});
test("wrong recipient, changed ciphertext, and wrong sender cannot authenticate", async () => {
  const other = await generateKeyPair("RSA-OAEP-256");
  await assert.rejects(compactDecrypt(fixture.envelope.jwe, other.privateKey));
  const parts = fixture.envelope.jwe.split(".");
  parts[3] = (parts[3][0] === "A" ? "B" : "A") + parts[3].slice(1);
  await assert.rejects(
    compactDecrypt(
      parts.join("."),
      await importJWK(fixture.encryptionPrivate, "RSA-OAEP-256"),
    ),
  );
  const encrypted = await compactDecrypt(
    fixture.envelope.jwe,
    await importJWK(fixture.encryptionPrivate, "RSA-OAEP-256"),
  );
  const wrongSigner = await generateKeyPair("ES256");
  await assert.rejects(
    compactVerify(encrypted.plaintext, wrongSigner.publicKey, {
      algorithms: ["ES256"],
    }),
  );
});
