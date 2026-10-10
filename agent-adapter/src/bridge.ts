import { randomUUID } from "node:crypto";
import { calculateJwkThumbprint, importJWK } from "jose";
import {
  canonical,
  decrypt,
  encrypt,
  fingerprint,
  generateIdentity,
  identityId,
  pairingOffer,
  publicIdentity,
  verifyObject,
  type Context,
  type Envelope,
  type Identity,
} from "./crypto.js";
import { validateProtocol } from "./protocol.js";

export type Job = {
  envelope: Envelope;
  scope: Record<string, unknown>;
  result?: Record<string, unknown>;
  resultDigest?: string;
};
export type BridgeState = {
  identity: Identity;
  offer?: string;
  pairing?: { identity: Identity; epoch: string };
  jobs: Record<string, Job>;
};
export function validatePublicIdentity(value: Identity): void {
  if (
    canonical(value) !== canonical(publicIdentity(value)) ||
    value.signing.kty !== "EC" ||
    value.signing.crv !== "P-256" ||
    value.encryption.kty !== "RSA" ||
    value.encryption.e !== "AQAB" ||
    Buffer.from(value.encryption.n ?? "", "base64url").length !== 256 ||
    Buffer.from(value.signing.x ?? "", "base64url").length !== 32 ||
    Buffer.from(value.signing.y ?? "", "base64url").length !== 32
  )
    throw new Error("invalid_pairing");
}
export class Bridge {
  private tail: Promise<unknown> = Promise.resolve();
  private failed = false;
  constructor(
    public state: BridgeState,
    private save: (state: BridgeState) => Promise<void>,
    private clock: () => number = () => Math.floor(Date.now() / 1000),
  ) {}
  static async create(
    save: (state: BridgeState) => Promise<void>,
    clock?: () => number,
  ): Promise<Bridge> {
    const state: BridgeState = { identity: await generateIdentity(), jobs: {} };
    await save(state);
    return new Bridge(state, save, clock);
  }
  private run<T>(task: () => Promise<T>): Promise<T> {
    const next = this.tail.then(async () => {
      if (this.failed) throw new Error("storage_unavailable");
      return task();
    });
    this.tail = next.catch(() => {});
    return next;
  }
  private async persist(): Promise<void> {
    try {
      await this.save(this.state);
    } catch {
      this.failed = true;
      throw new Error("storage_unavailable");
    }
  }
  offer(): Promise<{ offer: string; fingerprint: string }> {
    return this.run(async () => {
      if (this.state.pairing) throw new Error("already_paired");
      this.state.offer = await pairingOffer(this.state.identity, this.clock());
      await this.persist();
      return {
        offer: this.state.offer,
        fingerprint: fingerprint(publicIdentity(this.state.identity)),
      };
    });
  }
  accept(receipt: string, expectedDeviceFingerprint: string): Promise<void> {
    return this.run(async () => {
      if (this.state.pairing || !this.state.offer || receipt.length > 5000)
        throw new Error("invalid_pairing");
      const unsafe = JSON.parse(
        Buffer.from(receipt.split(".")[1] ?? "", "base64url").toString(),
      );
      const identity = unsafe.identity as Identity;
      validatePublicIdentity(identity);
      if (
        fingerprint(identity) !== expectedDeviceFingerprint.trim().toLowerCase()
      )
        throw new Error("invalid_pairing");
      const verified = await verifyObject(
        identity.signing,
        receipt,
        "agw+pairing",
      );
      if (
        canonical(Object.keys(verified).sort()) !==
        canonical([
          "agentId",
          "epoch",
          "expiresAt",
          "identity",
          "issuedAt",
          "kind",
          "nonce",
          "offerDigest",
          "version",
        ])
      )
        throw new Error("invalid_pairing");
      const offer = await verifyObject(
        publicIdentity(this.state.identity).signing,
        this.state.offer,
        "agw+pairing",
      );
      const { createHash } = await import("node:crypto");
      const digest = createHash("sha256")
        .update(canonical(this.state.offer))
        .digest("hex");
      if (
        verified.version !== 1 ||
        verified.kind !== "accept" ||
        verified.nonce !== offer.nonce ||
        verified.offerDigest !== digest ||
        verified.agentId !== (await identityId(this.state.identity)) ||
        verified.expiresAt !== offer.expiresAt ||
        typeof verified.issuedAt !== "number" ||
        !Number.isInteger(verified.issuedAt) ||
        verified.issuedAt > this.clock() ||
        verified.issuedAt < (offer.issuedAt as number) ||
        (verified.expiresAt as number) <= this.clock()
      )
        throw new Error("invalid_pairing");
      validateProtocol(
        "context",
        {
          version: 1,
          direction: "request",
          requestId: randomUUID(),
          sender: await identityId(this.state.identity),
          recipient: await calculateJwkThumbprint(identity.signing),
          pairingEpoch: verified.epoch,
          issuedAt: verified.issuedAt,
          expiresAt: verified.expiresAt,
        },
        this.clock(),
      );
      await importJWK(identity.signing, "ES256");
      await importJWK(identity.encryption, "RSA-OAEP-256");
      this.state.pairing = { identity, epoch: verified.epoch as string };
      delete this.state.offer;
      await this.persist();
    });
  }
  request(
    payload: Record<string, unknown>,
  ): Promise<{ requestId: string; status: string; envelope: Envelope }> {
    return this.run(async () => {
      const pair = this.state.pairing;
      if (!pair) throw new Error("unpaired");
      const now = this.clock();
      for (const [id, job] of Object.entries(this.state.jobs))
        if (job.envelope.context.expiresAt + 86400 < now)
          delete this.state.jobs[id];
      if (Object.keys(this.state.jobs).length >= 20)
        throw new Error("capacity");
      validateProtocol("request", payload, now);
      if (
        payload.operation !== "search" ||
        (payload.until as number) > now ||
        (payload.until as number) - (payload.since as number) > 30 * 86400 ||
        /\*|(^|\s)(after|before|newer|older|newer_than|older_than):/i.test(
          payload.query as string,
        ) ||
        !(payload.purpose as string).trim()
      )
        throw new Error("invalid_request");
      const context: Context = {
        version: 1,
        direction: "request",
        requestId: randomUUID(),
        sender: await identityId(this.state.identity),
        recipient: await identityId(pair.identity),
        pairingEpoch: pair.epoch,
        issuedAt: now,
        expiresAt: now + 300,
      };
      const envelope = await encrypt(
        this.state.identity,
        pair.identity,
        context,
        payload,
      );
      this.state.jobs[context.requestId] = { envelope, scope: payload };
      await this.persist();
      return {
        requestId: context.requestId,
        status: "pending_device_review",
        envelope,
      };
    });
  }
  submit(envelope: Envelope): Promise<Record<string, unknown>> {
    return this.run(async () => {
      const pair = this.state.pairing,
        job = this.state.jobs[envelope.context?.requestId];
      if (!pair || !job) throw new Error("unknown_request");
      const c = job.envelope.context;
      const expected: Context = {
        ...c,
        direction: "result",
        sender: c.recipient,
        recipient: c.sender,
      };
      const result = await decrypt(
        this.state.identity,
        pair.identity,
        envelope,
        expected,
        this.clock(),
      );
      const messages = result.messages as Record<string, unknown>[];
      const scope = job.scope;
      if (!scope || messages.length > (scope.maxResults as number))
        throw new Error("invalid_result");
      for (const message of messages) {
        if (
          Object.keys(message).some(
            (k) => !(scope.fields as string[]).includes(k),
          ) ||
          (message.date !== undefined &&
            ((message.date as number) < (scope.since as number) ||
              (message.date as number) >= (scope.until as number)))
        )
          throw new Error("invalid_result");
      }
      const digest = canonical(envelope);
      if (job.resultDigest && job.resultDigest !== digest)
        throw new Error("replay");
      job.result = result;
      job.resultDigest = digest;
      await this.persist();
      return result;
    });
  }
  status(id: string): Promise<Record<string, unknown>> {
    return this.run(async () => {
      const job = this.state.jobs[id];
      if (!this.state.pairing || !job) throw new Error("unknown_request");
      if (job.envelope.context.expiresAt <= this.clock())
        return { status: "expired", messages: [] };
      return (
        job.result ?? {
          status: "pending_device_review",
          requestId: id,
          envelope: job.envelope,
        }
      );
    });
  }
  unpair(): Promise<void> {
    return this.run(async () => {
      delete this.state.pairing;
      delete this.state.offer;
      this.state.jobs = {};
      await this.persist();
    });
  }
}
