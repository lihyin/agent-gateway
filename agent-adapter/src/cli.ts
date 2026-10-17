import { readFile } from "node:fs/promises";
import { openBridge } from "./store.js";

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
} catch {
  process.stderr.write(
    "Operation failed. Check pairing, input, expiry, and state permissions.\n",
  );
  process.exitCode = 1;
} finally {
  await close();
}
