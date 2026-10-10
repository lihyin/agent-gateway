import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { importJWK, compactDecrypt, compactVerify } from "jose";
const fixture = JSON.parse(
  await readFile("protocol/fixtures/crypto.json", "utf8"),
);
const serialized = JSON.parse(
  await readFile("mobile/.dart_tool/crypto-interop.json", "utf8"),
);
const decrypted = await compactDecrypt(
  serialized.jwe,
  await importJWK(fixture.encryptionPrivate, "RSA-OAEP-256"),
  {
    keyManagementAlgorithms: ["RSA-OAEP-256"],
    contentEncryptionAlgorithms: ["A256GCM"],
  },
);
const verified = await compactVerify(
  decrypted.plaintext,
  await importJWK(fixture.signingPublic, "ES256"),
  { algorithms: ["ES256"] },
);
assert.deepEqual(JSON.parse(new TextDecoder().decode(verified.payload)), {
  context: fixture.envelope.context,
  payload: fixture.payload,
});
console.log("Dart-to-TypeScript nested JOSE interoperability passed");
