import { randomBytes } from "node:crypto";
import { CompactEncrypt, compactDecrypt } from "jose";
import { SRP, SrpClient } from "fast-srp-hap";
import WebSocket from "ws";
import type { Bridge } from "./bridge.js";

export type PairingSetup = {
  origin: string;
  session: string;
  code: string;
  expiresAt: number;
};
export function parsePairingSetup(
  input: string,
  now = Math.floor(Date.now() / 1000),
): PairingSetup {
  if (input.length > 2048) throw new Error("invalid_pairing_setup");
  const value = JSON.parse(
    Buffer.from(input.trim().replace(/^AGW1\./, ""), "base64url").toString(),
  ) as PairingSetup;
  const url = new URL(value.origin);
  if (
    !input.trim().startsWith("AGW1.") ||
    Object.keys(value).sort().join() !== "code,expiresAt,origin,session" ||
    url.protocol !== "https:" ||
    url.origin !== value.origin ||
    url.username ||
    url.password ||
    url.port ||
    !/^[a-z0-9.-]+\.[a-z]{2,}$/i.test(url.hostname) ||
    !/^[a-f0-9]{64}$/.test(value.session) ||
    typeof value.code !== "string" ||
    !/^[0-9]{8}$/.test(value.code) ||
    !Number.isInteger(value.expiresAt) ||
    value.expiresAt <= now ||
    value.expiresAt > now + 300
  )
    throw new Error("invalid_pairing_setup");
  return value;
}
export function srpClient(
  setup: PairingSetup,
  salt: string,
  server: string,
  secret = randomBytes(32),
) {
  if (!/^[a-f0-9]{64}$/.test(salt) || !/^[a-f0-9]{512}$/.test(server))
    throw new Error("invalid_pairing");
  const client = new SrpClient(
    { ...SRP.params[2048], hash: "sha256" },
    Buffer.from(salt, "hex"),
    Buffer.from(`agw-pin-v1:${setup.origin}:${setup.session}`),
    Buffer.from(setup.code),
    secret,
    false,
  );
  client.setB(Buffer.from(server, "hex"));
  return client;
}
export async function sealPairing(
  key: Uint8Array,
  setup: PairingSetup,
  kind: string,
  data: Record<string, unknown> = {},
) {
  return new CompactEncrypt(
    Buffer.from(
      JSON.stringify({
        version: 1,
        origin: setup.origin,
        session: setup.session,
        expiresAt: setup.expiresAt,
        kind,
        ...data,
      }),
    ),
  )
    .setProtectedHeader({ alg: "dir", enc: "A256GCM", typ: "agw+pin" })
    .encrypt(key);
}
export async function openPairing(
  key: Uint8Array,
  setup: PairingSetup,
  compact: string,
  kind: string,
) {
  if (compact.length > 8192) throw new Error("invalid_pairing");
  const { plaintext, protectedHeader } = await compactDecrypt(compact, key, {
    keyManagementAlgorithms: ["dir"],
    contentEncryptionAlgorithms: ["A256GCM"],
  });
  const value = JSON.parse(Buffer.from(plaintext).toString());
  const extra =
    kind === "offer"
      ? ["offer"]
      : kind === "receipt"
        ? ["fingerprint", "receipt"]
        : [];
  if (
    Object.keys(value).sort().join() !==
    ["version", "origin", "session", "expiresAt", "kind", ...extra]
      .sort()
      .join()
  )
    throw new Error("invalid_pairing");
  if (
    Object.keys(protectedHeader).sort().join() !== "alg,enc,typ" ||
    protectedHeader.typ !== "agw+pin" ||
    value.version !== 1 ||
    value.origin !== setup.origin ||
    value.session !== setup.session ||
    value.expiresAt !== setup.expiresAt ||
    value.expiresAt <= Math.floor(Date.now() / 1000) ||
    value.kind !== kind
  )
    throw new Error("invalid_pairing");
  return value as Record<string, unknown>;
}

// One outbound connection inside Muse. Never sends the PIN or SRP verifier to the relay.
export async function pairWithCode(
  bridge: Bridge,
  setup: PairingSetup,
  signal?: AbortSignal,
  connect: (url: string, options: WebSocket.ClientOptions) => WebSocket = (
    url,
    options,
  ) => new WebSocket(url, options),
): Promise<void> {
  if (signal?.aborted || Date.now() >= setup.expiresAt * 1000)
    throw new Error("pairing_cancelled_or_expired");
  if (bridge.state.pairing) throw new Error("already_paired");
  const socket = connect(
    `${setup.origin.replace("https:", "wss:")}/v1/pairing/${setup.session}/agent`,
    {
      maxPayload: 8192,
      handshakeTimeout: 15000,
      followRedirects: false,
    },
  );
  let key: Buffer | undefined;
  try {
    await new Promise<void>((resolve, reject) => {
      let stage = "challenge",
        done = false,
        processing = false;
      const finish = (error?: Error) => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        signal?.removeEventListener("abort", abort);
        if (error) reject(error);
        else resolve();
      };
      const abort = () => finish(new Error("pairing_cancelled"));
      const timer = setTimeout(
        () => finish(new Error("pairing_expired")),
        Math.max(0, setup.expiresAt * 1000 - Date.now()),
      );
      signal?.addEventListener("abort", abort, { once: true });
      if (signal?.aborted) abort();
      socket.on("error", () => finish(new Error("pairing_unavailable")));
      socket.on("unexpected-response", (_req, response) => {
        response.resume();
        finish(new Error("pairing_unavailable"));
      });
      socket.on("close", () => finish(new Error("pairing_interrupted")));
      socket.on("message", async (data, binary) => {
        if (done) return;
        if (processing || binary) {
          finish(new Error("invalid_pairing"));
          return;
        }
        processing = true;
        try {
          if (Date.now() >= setup.expiresAt * 1000)
            throw new Error("pairing_expired");
          const frame = JSON.parse(data.toString());
          if (stage !== "challenge" && Object.keys(frame).join() !== "jwe")
            throw new Error("invalid_pairing");
          if (stage === "challenge") {
            if (
              Object.keys(frame).sort().join() !== "B,expiresAt,kind,salt" ||
              frame.kind !== "challenge" ||
              frame.expiresAt !== setup.expiresAt
            )
              throw new Error("invalid_pairing");
            const client = srpClient(setup, frame.salt, frame.B);
            key = client.computeK();
            stage = "ready";
            socket.send(
              JSON.stringify({
                kind: "proof",
                A: client.computeA().toString("hex"),
                M1: client.computeM1().toString("hex"),
              }),
            );
          } else if (stage === "ready") {
            await openPairing(key!, setup, frame.jwe, "ready");
            const { offer } = await bridge.offer();
            stage = "receipt";
            socket.send(
              JSON.stringify({
                jwe: await sealPairing(key!, setup, "offer", { offer }),
              }),
            );
          } else if (stage === "receipt") {
            const receipt = await openPairing(
              key!,
              setup,
              frame.jwe,
              "receipt",
            );
            if (done || signal?.aborted) throw new Error("pairing_cancelled");
            await bridge.accept(
              receipt.receipt as string,
              receipt.fingerprint as string,
              () =>
                !done &&
                !signal?.aborted &&
                Date.now() < setup.expiresAt * 1000,
            );
            socket.send(
              JSON.stringify({
                jwe: await sealPairing(key!, setup, "complete"),
              }),
            );
            finish();
          } else throw new Error("invalid_pairing");
        } catch {
          finish(new Error("pairing_failed"));
        } finally {
          processing = false;
        }
      });
    });
  } finally {
    key?.fill(0);
    socket.close();
  }
}
