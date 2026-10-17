import { randomBytes } from "node:crypto";
import WebSocket from "ws";

// Public, disposable live-channel smoke check. No PIN, source request, push or keys.
const origin = process.env.RELAY_URL;
const url = new URL(origin);
if (url.protocol !== "https:" || url.origin !== origin)
  throw new Error("Pairing verification requires an exact HTTPS origin");
const session = randomBytes(32).toString("hex");
const base = `${origin.replace("https:", "wss:")}/v1/pairing/${session}`;
const device = new WebSocket(`${base}/device`, {
  followRedirects: false,
  handshakeTimeout: 12000,
});
let agent;
try {
  await new Promise((resolve, reject) => {
    const timeout = setTimeout(
      () => finish(new Error("Pairing verification timed out")),
      20000,
    );
    let done = false;
    function finish(error) {
      if (done) return;
      done = true;
      clearTimeout(timeout);
      if (error) reject(error);
      else resolve();
    }
    const fail = () =>
      finish(
        new Error("Pairing connection failed; check relay bindings and origin"),
      );
    device.on("error", fail);
    device.on("close", () => {
      if (!done) fail();
    });
    device.on("open", () => {
      agent = new WebSocket(`${base}/agent`, {
        followRedirects: false,
        handshakeTimeout: 12000,
      });
      agent.on("error", fail);
      agent.on("close", () => {
        if (!done) fail();
      });
      agent.on("message", (data) => {
        if (data.toString() !== '{"smoke":"public transport test"}') {
          fail();
          return;
        }
        finish();
      });
    });
    device.on("message", (data) => {
      try {
        if (JSON.parse(data.toString()).kind !== "joined") {
          fail();
          return;
        }
        device.send('{"smoke":"public transport test"}');
      } catch {
        fail();
      }
    });
  });
  console.log("Deployed pairing WebSocket forwarding verified.");
} finally {
  device.terminate();
  agent?.terminate();
}
