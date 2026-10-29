import { readFile } from "node:fs/promises";
import { openBridge } from "./store.js";
import { relayRequest } from "./relay-client.js";
import { createInterface } from "node:readline/promises";
import { pairWithCode, parsePairingSetup } from "./pin-pairing.js";

const path = process.env.GATEWAY_AGENT_STATE;
if (!path)
  throw new Error(
    "Set GATEWAY_AGENT_STATE to a private, backup-excluded state file.",
  );
const { bridge, close } = await openBridge(path);
try {
  const [command, input, fingerprint] = process.argv.slice(2);
  let result: unknown;
  switch (command) {
    case "pair": {
      if (input !== undefined && input !== "--replace")
        throw new Error("invalid_pairing_option");
      const lines = createInterface({ input: process.stdin, terminal: false });
      process.stderr.write(
        "Paste the AGW1 setup line from your iPhone, then press Enter:\n",
      );
      try {
        const iterator = lines[Symbol.asyncIterator]();
        const line = await iterator.next();
        if (line.done) throw new Error("pairing_setup_required");
        await pairWithCode(
          bridge,
          parsePairingSetup(line.value),
          undefined,
          undefined,
          { replaceExisting: input === "--replace" },
        );
        result = {
          status: "paired",
          transportConfiguration: await bridge.transportConfiguration(),
        };
      } finally {
        lines.close();
      }
      break;
    }
    case "offer":
      result = await bridge.offer();
      break;
    case "accept":
      await bridge.accept(
        (await readFile(input, "utf8")).trim(),
        fingerprint ?? "",
      );
      result = { status: "paired" };
      break;
    case "request":
      result = await bridge.request(JSON.parse(await readFile(input, "utf8")));
      break;
    case "relay-request": {
      const { requestId, ...scope } = JSON.parse(await readFile(input, "utf8"));
      if (typeof requestId !== "string") throw new Error("invalid_request");
      const job = await bridge.request(scope, requestId);
      result = await relayRequest(
        bridge,
        job.requestId,
        process.env.RELAY_URL ?? "",
      );
      break;
    }
    case "submit":
      result = await bridge.submit(JSON.parse(await readFile(input, "utf8")));
      break;
    case "status":
      result = await bridge.status(input);
      break;
    case "transport-config":
      result = await bridge.transportConfiguration();
      break;
    case "unpair":
      await bridge.unpair();
      result = { status: "unpaired" };
      break;
    default:
      throw new Error("Unknown command");
  }
  process.stdout.write(`${JSON.stringify(result)}\n`);
} catch (error) {
  process.stderr.write(
    error instanceof Error && error.message === "already_paired"
      ? "This Muse state still remembers a pairing. Unpairing the iPhone does not erase this runtime's local state. Stop its MCP process, then run pair --replace with a fresh iPhone setup line to re-pair. Replacement requires the new code and phone confirmation.\n"
      : error instanceof Error && error.message === "relay_pairing_rejected"
        ? "The relay rejected this pairing. If the iPhone was unpaired, obtain a fresh setup prompt and re-pair with pair --replace; then reconnect Gmail and enable Relay notifications on the phone. Local saved pairing state does not establish current relay access.\n"
        : error instanceof Error && error.message === "invalid_pairing_option"
          ? "Use pair or pair --replace, and provide the AGW1 setup line on standard input.\n"
          : "Operation failed. Check pairing, input, expiry, and state permissions.\n",
  );
  process.exitCode = 1;
} finally {
  await close();
}
