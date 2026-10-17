import assert from "node:assert/strict";
import { createServer, request } from "node:http";
import { readFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import test from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { Bridge } from "../src/bridge.js";
import { publicIdentity, signObject } from "../src/crypto.js";
import { remoteHandler } from "../src/remote.js";

const f = JSON.parse(
  readFileSync(
    new URL("../../protocol/fixtures/pairing.json", import.meta.url),
    "utf8",
  ),
);
test("real HTTP MCP client discovers remote tools and shares durable jobs with authenticated device sync", async () => {
  const now = Math.floor(Date.now() / 1000);
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
  const config = {
    publicOrigin: "https://bridge.example.com",
    relayOrigin: "https://relay.example.com",
    mcpToken: "m".repeat(40),
    relayToken: "r".repeat(40),
  };
  const handler = remoteHandler(bridge, config);
  const server = createServer((req, res) => {
    void handler(req, res);
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as { port: number }).port;
  const call = (
    path: string,
    token: string,
    host = "bridge.example.com",
    origin?: string,
    body = "{}",
    type = "application/json",
  ) =>
    new Promise<{ status: number; text: string }>((resolve, reject) => {
      const req = request(
        {
          host: "127.0.0.1",
          port,
          path,
          method: "POST",
          headers: {
            Host: host,
            Authorization: `Bearer ${token}`,
            "Content-Type": type,
            ...(origin ? { Origin: origin } : {}),
          },
        },
        (res) => {
          let text = "";
          res.on("data", (chunk) => {
            text += chunk;
          });
          res.on("end", () => resolve({ status: res.statusCode!, text }));
        },
      );
      req.on("error", reject);
      req.end(body);
    });
  const client = new Client({ name: "remote-test", version: "1" });
  try {
    assert.equal((await call("/mcp", "wrong")).status, 401);
    assert.equal((await call("/mcp", config.relayToken)).status, 401);
    assert.equal(
      (await call("/mcp", config.mcpToken, "attacker.example.com")).status,
      403,
    );
    assert.equal(
      (
        await call(
          "/mcp",
          config.mcpToken,
          "bridge.example.com",
          "https://attacker.example.com",
        )
      ).status,
      403,
    );
    assert.equal((await call("/transport/sync", config.mcpToken)).status, 401);
    assert.equal(
      (await call("/mcp", config.mcpToken, undefined, undefined, "[]")).status,
      400,
    );
    await client.connect(
      new StreamableHTTPClientTransport(
        new URL(`http://127.0.0.1:${port}/mcp`),
        {
          requestInit: {
            headers: {
              Host: "bridge.example.com",
              Authorization: `Bearer ${config.mcpToken}`,
            },
          },
          // Node fetch controls Host itself; emulate the production TLS proxy here.
          fetch: async (_url, init) =>
            new Promise<Response>((resolve, reject) => {
              const headers = Object.fromEntries(
                new Headers(init?.headers).entries(),
              );
              const req = request(
                {
                  host: "127.0.0.1",
                  port,
                  path: "/mcp",
                  method: init?.method,
                  headers: { ...headers, Host: "bridge.example.com" },
                },
                (res) => {
                  const chunks: Buffer[] = [];
                  res.on("data", (chunk) => chunks.push(Buffer.from(chunk)));
                  res.on("end", () =>
                    resolve(
                      new Response(Buffer.concat(chunks), {
                        status: res.statusCode!,
                        headers: {
                          "Content-Type": String(
                            res.headers["content-type"] ?? "",
                          ),
                        },
                      }),
                    ),
                  );
                },
              );
              req.on("error", reject);
              req.end(init?.body);
            }),
        },
      ),
    );
    assert.deepEqual(
      (await client.listTools()).tools.map((tool) => tool.name).sort(),
      ["gateway_request_status", "gmail_request_preview"],
    );
    const requestId = randomUUID();
    const args = {
      requestId,
      query: "subject:AGWTEST",
      purpose: "Network test",
      fields: ["id", "subject"],
      since: now - 86400,
      until: now,
      maxResults: 5,
    };
    const created = await client.callTool({
      name: "gmail_request_preview",
      arguments: args,
    });
    assert.deepEqual(created.structuredContent, {
      requestId,
      status: "pending_device_review",
    });
    assert.deepEqual(
      (
        await client.callTool({
          name: "gmail_request_preview",
          arguments: args,
        })
      ).structuredContent,
      created.structuredContent,
    );
    const pair = await bridge.transportConfiguration();
    const signed = await signObject(
      f.device,
      {
        version: 1,
        audience: config.relayOrigin,
        deviceId: pair.deviceId,
        agentId: pair.agentId,
        pairingEpoch: pair.pairingEpoch,
        issuedAt: now,
        expiresAt: now + 30,
        knownRequests: [],
        result: null,
      },
      "agw+sync",
    );
    const sync = await call(
      "/transport/sync",
      config.relayToken,
      undefined,
      undefined,
      signed,
      "application/jose",
    );
    assert.equal(sync.status, 200);
    assert.equal(JSON.parse(sync.text).envelope.context.requestId, requestId);
    assert.ok(!sync.text.includes("subject:AGWTEST"));
    assert.deepEqual(
      (
        await client.callTool({
          name: "gateway_request_status",
          arguments: { requestId },
        })
      ).structuredContent,
      { requestId, status: "pending_device_review" },
    );
    await bridge.unpair();
    assert.equal(
      (
        await call(
          "/transport/sync",
          config.relayToken,
          undefined,
          undefined,
          signed,
          "application/jose",
        )
      ).status,
      400,
    );
  } finally {
    await client.close();
    server.closeAllConnections();
    await new Promise<void>((resolve, reject) =>
      server.close((error) => (error ? reject(error) : resolve())),
    );
  }
});
