import { writeFile } from "node:fs/promises";
import {
  generateIdentity,
  identityId,
  publicIdentity,
  pairingOffer,
  fingerprint,
  encrypt,
} from "../agent-adapter/src/crypto.ts";
const agent = await generateIdentity();
const device = await generateIdentity();
const now = 100;
const context = {
  version: 1,
  direction: "request",
  requestId: "00000000-0000-4000-8000-000000000003",
  sender: await identityId(agent),
  recipient: await identityId(device),
  pairingEpoch: "00000000-0000-4000-8000-000000000004",
  issuedAt: now,
  expiresAt: now + 300,
};
const payload = {
  source: "gmail",
  operation: "search",
  query: "subject:AGWTEST",
  purpose: "Test preview",
  fields: ["id", "date", "subject"],
  since: 1,
  until: now,
  maxResults: 5,
};
await writeFile(
  "protocol/fixtures/pairing.json",
  JSON.stringify(
    {
      testOnly: true,
      agent,
      device,
      fingerprint: fingerprint(publicIdentity(agent)),
      offer: await pairingOffer(agent, now),
      context,
      payload,
      envelope: await encrypt(agent, publicIdentity(device), context, payload),
    },
    null,
    2,
  ) + "\n",
);
