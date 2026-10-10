import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";
import test from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import {
  StdioClientTransport,
  getDefaultEnvironment,
} from "@modelcontextprotocol/sdk/client/stdio.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { Bridge } from "../src/bridge.js";
import { createMcpServer } from "../src/mcp.js";
import {
  encrypt,
  publicIdentity,
  type Context,
  type Envelope,
} from "../src/crypto.js";

const f = JSON.parse(
  readFileSync(
    new URL("../../protocol/fixtures/pairing.json", import.meta.url),
    "utf8",
  ),
);
test("MCP client lists tools, creates idempotent pending review, and receives only authenticated results", async () => {
  let now = 100;
  const bridge = new Bridge(
    {
      identity: f.agent,
      pairing: {
        identity: publicIdentity(f.device),
        epoch: f.context.pairingEpoch,
      },
      jobs: {},
    },
    async () => {},
    () => now,
  );
  const server = createMcpServer(bridge),
    client = new Client({ name: "test-client", version: "1.0.0" });
  const [a, b] = InMemoryTransport.createLinkedPair();
  await server.connect(a);
  await client.connect(b);
  try {
    const list = await client.listTools();
    assert.deepEqual(list.tools.map((t) => t.name).sort(), [
      "gateway_request_status",
      "gateway_submit_encrypted_result",
      "gmail_request_preview",
    ]);
    assert.ok(!list.tools.some((t) => /pair|approve|token/.test(t.name)));
    const args = {
      requestId: randomUUID(),
      query: f.payload.query,
      purpose: f.payload.purpose,
      fields: f.payload.fields,
      since: 1,
      until: 100,
      maxResults: 5,
    };
    const first = await client.callTool({
      name: "gmail_request_preview",
      arguments: args,
    });
    assert.equal(first.isError, undefined);
    const job = first.structuredContent as {
      requestId: string;
      status: string;
      envelope: Envelope;
    };
    assert.equal(job.status, "pending_device_review");
    const retry = await client.callTool({
      name: "gmail_request_preview",
      arguments: args,
    });
    assert.deepEqual(retry.structuredContent, job);
    const changed = await client.callTool({
      name: "gmail_request_preview",
      arguments: { ...args, purpose: "Changed" },
    });
    assert.equal(changed.isError, true);
    for (const bad of [
      { ...args, fields: ["body"] },
      { ...args, query: "*" },
      { ...args, token: "secret" },
      { ...args, maxResults: 11 },
    ]) {
      assert.equal(
        (
          await client.callTool({
            name: "gmail_request_preview",
            arguments: bad,
          })
        ).isError,
        true,
      );
    }
    const c = job.envelope.context;
    const context: Context = {
      ...c,
      direction: "result",
      sender: c.recipient,
      recipient: c.sender,
    };
    const wider = await encrypt(f.device, publicIdentity(f.agent), context, {
      status: "allowed",
      messages: [{ from: "Unrequested" }],
    });
    assert.equal(
      (
        await client.callTool({
          name: "gateway_submit_encrypted_result",
          arguments: { envelope: JSON.stringify(wider) },
        })
      ).isError,
      true,
    );
    assert.equal(
      (
        await client.callTool({
          name: "gateway_submit_encrypted_result",
          arguments: {
            envelope: JSON.stringify({ status: "allowed", messages: [] }),
          },
        })
      ).isError,
      true,
    );
    const result = await encrypt(f.device, publicIdentity(f.agent), context, {
      status: "allowed",
      messages: [{ subject: "Approved filtered data" }],
    });
    const received = await client.callTool({
      name: "gateway_submit_encrypted_result",
      arguments: { envelope: JSON.stringify(result) },
    });
    assert.deepEqual(received.structuredContent, {
      status: "allowed",
      messages: [{ subject: "Approved filtered data" }],
    });
    const status = await client.callTool({
      name: "gateway_request_status",
      arguments: { requestId: job.requestId },
    });
    assert.deepEqual(status.structuredContent, received.structuredContent);
    now = 400;
    assert.deepEqual(
      (
        await client.callTool({
          name: "gateway_request_status",
          arguments: { requestId: job.requestId },
        })
      ).structuredContent,
      { status: "expired", messages: [] },
    );
    assert.equal(
      (
        await client.callTool({
          name: "gateway_submit_encrypted_result",
          arguments: { envelope: JSON.stringify(result) },
        })
      ).isError,
      true,
    );
  } finally {
    await client.close();
    await server.close();
  }
});
test("actual stdio process initializes, lists tools, and fails closed without pairing", async () => {
  const root = resolve(tmpdir()),
    directory = await mkdtemp(join(root, "agent-gateway-mcp-test-"));
  assert.ok(resolve(directory).startsWith(root + sep));
  const state = join(directory, "state.json");
  await writeFile(
    state,
    JSON.stringify({ version: 1, state: { identity: f.agent, jobs: {} } }),
    { mode: 0o600 },
  );
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [
      "--import",
      "tsx",
      fileURLToPath(new URL("../src/mcp-server.ts", import.meta.url)),
    ],
    cwd: fileURLToPath(new URL("../../", import.meta.url)),
    env: { ...getDefaultEnvironment(), GATEWAY_AGENT_STATE: state },
    stderr: "pipe",
  });
  let stderr = "";
  transport.stderr?.on("data", (chunk) => {
    stderr += String(chunk);
  });
  const client = new Client({ name: "stdio-test", version: "1.0.0" });
  try {
    await client.connect(transport);
    assert.equal((await client.listTools()).tools.length, 3);
    const response = await client.callTool({
      name: "gmail_request_preview",
      arguments: {
        requestId: randomUUID(),
        query: "subject:AGWTEST",
        purpose: "Preview",
        fields: ["subject"],
        since: 1,
        until: 100,
        maxResults: 1,
      },
    });
    assert.equal(response.isError, true);
    assert.equal(stderr, "");
  } finally {
    await client.close();
    await rm(directory, { recursive: true, force: true });
  }
});
