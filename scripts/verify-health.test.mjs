import assert from "node:assert/strict";
import test from "node:test";
import { verifyHealth } from "./verify-health.mjs";

const expected = {
  relayUrl: "https://relay.test",
  revision: "tested-revision",
  environment: "staging",
};
const healthy = {
  status: "ok",
  service: "agent-gateway-relay",
  environment: "staging",
  revision: "tested-revision",
  sourceAccessEnabled: false,
};

test("health waits through propagation and verifies the exact release", async () => {
  const responses = [
    new Response("<!DOCTYPE html>", { status: 404 }),
    new Response("<!DOCTYPE html>"),
    Response.json({ ...healthy, revision: "previous-revision" }),
    Response.json(healthy),
  ];
  let waits = 0;
  const result = await verifyHealth({
    ...expected,
    attempts: 4,
    sleep: async (ms) => {
      assert.equal(ms, 5000);
      waits++;
    },
    fetchImpl: async (url, options) => {
      assert.equal(url.href, "https://relay.test/health");
      assert.equal(options.redirect, "error");
      return responses.shift();
    },
  });
  assert.deepEqual(result, healthy);
  assert.equal(waits, 3);
});

test("persistent unavailable or stale health fails within bounded attempts", async () => {
  for (const response of [
    () => new Response("unavailable", { status: 503 }),
    () => Response.json({ ...healthy, revision: "previous-revision" }),
  ]) {
    let calls = 0;
    await assert.rejects(
      verifyHealth({
        ...expected,
        attempts: 2,
        sleep: async () => {},
        fetchImpl: async () => {
          calls++;
          return response();
        },
      }),
      /verification failed/,
    );
    assert.equal(calls, 2);
  }
});

test("wrong service, environment, or enabled source access fails immediately", async () => {
  for (const change of [
    { service: "other" },
    { environment: "production" },
    { sourceAccessEnabled: true },
    { sourceAccessEnabled: undefined },
  ]) {
    await assert.rejects(
      verifyHealth({
        ...expected,
        sleep: async () => assert.fail("Unsafe health must not be retried"),
        fetchImpl: async () => Response.json({ ...healthy, ...change }),
      }),
      /relay boundary/,
    );
  }
});

test("health rejects HTTP or missing expected identity before fetching", async () => {
  for (const change of [
    { relayUrl: "http://relay.test" },
    { revision: undefined },
    { environment: undefined },
  ]) {
    await assert.rejects(
      verifyHealth({
        ...expected,
        ...change,
        fetchImpl: async () =>
          assert.fail("Invalid configuration must not fetch"),
      }),
    );
  }
});
