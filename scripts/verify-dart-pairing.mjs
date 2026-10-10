import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { Bridge } from "../agent-adapter/src/bridge.ts";
const fixture = JSON.parse(
  await readFile("protocol/fixtures/pairing.json", "utf8"),
);
const dart = JSON.parse(
  await readFile("mobile/.dart_tool/pairing-interop.json", "utf8"),
);
const bridge = new Bridge(
  { identity: fixture.agent, offer: fixture.offer, jobs: {} },
  async () => {},
  () => 100,
);
await bridge.accept(dart.receipt, dart.deviceFingerprint);
bridge.state.jobs[dart.request.context.requestId] = {
  envelope: dart.request,
  scope: fixture.payload,
};
const result = await bridge.submit(dart.result);
assert.equal(result.status, "allowed");
assert.equal(result.messages[0].subject, "Invoice for [redacted]");
console.log(
  "Dart pairing receipt and approved encrypted result verified in Node.",
);
