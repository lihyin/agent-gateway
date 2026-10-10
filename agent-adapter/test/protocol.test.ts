import assert from "node:assert/strict";
import test from "node:test";
import { validateProtocol } from "../src/protocol.js";

const context = {
  version: 1,
  direction: "request",
  requestId: "00000000-0000-4000-8000-000000000001",
  sender: "a".repeat(43),
  recipient: "b".repeat(43),
  pairingEpoch: "00000000-0000-4000-8000-000000000002",
  issuedAt: 100,
  expiresAt: 400,
};
test("protocol accepts valid context and rejects version, extra fields and expiry boundaries", () => {
  validateProtocol("context", context, 100);
  for (const bad of [
    { ...context, version: 2 },
    { ...context, risk: "low" },
    { ...context, expiresAt: 401 },
    { ...context, issuedAt: 101 },
    { ...context, direction: "unknown" },
  ])
    assert.throws(() => validateProtocol("context", bad, 100));
  assert.throws(() => validateProtocol("context", context, 400));
});
test("source scopes and denial payloads are closed", () => {
  const request = {
    source: "gmail",
    operation: "search",
    query: "invoice",
    purpose: "Find receipt",
    fields: ["subject"],
    since: 1,
    until: 100,
    maxResults: 5,
  };
  validateProtocol("request", request, 100);
  for (const bad of [
    { ...request, fields: ["body"] },
    { ...request, maxResults: 11 },
    { ...request, since: 100 },
    { ...request, token: "secret" },
    { ...request, fields: ["subject", "subject"] },
  ])
    assert.throws(() => validateProtocol("request", bad, 100));
  assert.throws(() =>
    validateProtocol(
      "result",
      { status: "denied", messages: [{ subject: "private" }] },
      100,
    ),
  );
});
test("request envelopes enforce encoded byte budgets", () => {
  assert.throws(() =>
    validateProtocol(
      "envelope",
      { context, jwe: `a.a.a.${"a".repeat(3500)}.a` },
      100,
    ),
  );
});
