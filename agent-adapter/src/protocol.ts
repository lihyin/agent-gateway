import { existsSync, readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { Ajv } from "ajv";
const addFormats = createRequire(import.meta.url)("ajv-formats") as (
  validator: Ajv,
) => void;

const ajv = new Ajv({ strict: true });
addFormats(ajv);
const schemaRoot = existsSync(
  new URL("../../protocol/schemas/", import.meta.url),
)
  ? new URL("../../protocol/schemas/", import.meta.url)
  : new URL("../../../protocol/schemas/", import.meta.url);
for (const name of [
  "context",
  "envelope",
  "request",
  "result",
  "route",
  "ack",
  "error",
]) {
  ajv.addSchema(
    JSON.parse(readFileSync(new URL(`${name}.json`, schemaRoot), "utf8")),
  );
}

export function validateProtocol(
  name: string,
  value: unknown,
  now: number,
): void {
  const validate = ajv.getSchema(
    `https://agent-gateway.invalid/protocol/v1/${name}`,
  );
  if (!validate || !validate(value)) throw new Error("invalid_request");
  const record = value as Record<string, unknown>;
  const context = (name === "envelope" ? record.context : record) as Record<
    string,
    unknown
  >;
  if (["context", "envelope", "route"].includes(name)) {
    const issued = context.issuedAt as number;
    const expires = context.expiresAt as number;
    if (
      issued > now ||
      expires <= now ||
      expires <= issued ||
      expires - issued > (name === "route" ? 86400 : 300)
    )
      throw new Error("expired");
  }
  if (
    name === "request" &&
    (record.since as number) >= (record.until as number)
  )
    throw new Error("invalid_request");
  if (name === "route") {
    const callback = new URL(record.callbackOrigin as string);
    if (
      callback.origin !== record.callbackOrigin ||
      callback.username ||
      callback.password ||
      callback.port ||
      /^\d+\./.test(callback.hostname) ||
      !callback.hostname.includes(".") ||
      callback.hostname.endsWith(".local")
    )
      throw new Error("invalid_route");
  }
  const size = Buffer.byteLength(JSON.stringify(value), "utf8");
  const limit =
    name === "request"
      ? 1200
      : name === "envelope" && context.direction === "request"
        ? 3500
        : name === "result"
          ? 50000
          : 65536;
  if (size > limit) throw new Error("oversize");
}
