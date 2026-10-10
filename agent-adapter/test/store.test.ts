import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { join, resolve, sep } from "node:path";
import { tmpdir } from "node:os";
import test from "node:test";
import { openBridge } from "../src/store.js";
import { fingerprint, publicIdentity } from "../src/crypto.js";

test("agent state survives restart and exclusive lock prevents concurrent writers", async () => {
  const root = resolve(tmpdir());
  const directory = await mkdtemp(join(root, "agent-gateway-test-"));
  assert.ok(resolve(directory).startsWith(root + sep));
  const path = join(directory, "state.json");
  let opened;
  try {
    opened = await openBridge(path);
    const first = fingerprint(publicIdentity(opened.bridge.state.identity));
    await assert.rejects(openBridge(path));
    await opened.bridge.offer();
    assert.equal(JSON.parse(await readFile(path, "utf8")).version, 1);
    await opened.close();
    opened = undefined;
    opened = await openBridge(path);
    assert.equal(
      fingerprint(publicIdentity(opened.bridge.state.identity)),
      first,
    );
    assert.ok(opened.bridge.state.offer);
  } finally {
    await opened?.close();
    await rm(directory, { recursive: true, force: true });
  }
});
