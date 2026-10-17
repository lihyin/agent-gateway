// Test-only Node peer for the Dart/Node pairing interoperability test.
import { createInterface } from "node:readline";
import { readFile } from "node:fs/promises";
import { Bridge } from "../agent-adapter/src/bridge.ts";
import {
  parsePairingSetup,
  srpClient,
  sealPairing,
  openPairing,
} from "../agent-adapter/src/pin-pairing.ts";
const lines = createInterface({ input: process.stdin });
const iterator = lines[Symbol.asyncIterator]();
const read = async () => JSON.parse((await iterator.next()).value);
const write = (value) => process.stdout.write(`${JSON.stringify(value)}\n`);
try {
  const { line, challenge, wrongCode } = await read();
  const setup = parsePairingSetup(line);
  const client = srpClient(
    wrongCode
      ? { ...setup, code: setup.code === "99999999" ? "00000000" : "99999999" }
      : setup,
    challenge.salt,
    challenge.B,
  );
  write({
    kind: "proof",
    A: client.computeA().toString("hex"),
    M1: client.computeM1().toString("hex"),
  });
  const key = client.computeK();
  await openPairing(key, setup, (await read()).jwe, "ready");
  const fixture = JSON.parse(
    await readFile("protocol/fixtures/pairing.json", "utf8"),
  );
  const bridge = new Bridge(
    { identity: fixture.agent, jobs: {} },
    async () => {},
  );
  const { offer } = await bridge.offer();
  write({ jwe: await sealPairing(key, setup, "offer", { offer }) });
  const receipt = await openPairing(key, setup, (await read()).jwe, "receipt");
  await bridge.accept(receipt.receipt, receipt.fingerprint);
  write({
    jwe: await sealPairing(key, setup, "complete"),
    paired: !!bridge.state.pairing,
  });
  key.fill(0);
} finally {
  lines.close();
}
