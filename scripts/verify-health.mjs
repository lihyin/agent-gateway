import { pathToFileURL } from "node:url";

export async function verifyHealth({
  relayUrl,
  revision,
  environment,
  fetchImpl = fetch,
  sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  attempts = 12,
}) {
  const url = new URL("/health", relayUrl);
  if (url.protocol !== "https:")
    throw new Error("Production/staging health requires HTTPS.");
  if (!revision || !["staging", "production"].includes(environment))
    throw new Error("Expected release revision and environment are required.");
  let failure = "Health endpoint unavailable";
  for (let attempt = 0; attempt < attempts; attempt++) {
    let health;
    try {
      const response = await fetchImpl(url, {
        signal: AbortSignal.timeout(10000),
        redirect: "error",
      });
      if (!response.ok) failure = `Health returned HTTP ${response.status}`;
      else health = await response.json();
    } catch {
      failure = "Health request failed or returned invalid JSON";
    }
    if (health) {
      if (
        health.service !== "agent-gateway-relay" ||
        health.sourceAccessEnabled !== false ||
        health.environment !== environment
      ) {
        throw new Error(
          "Deployed health violates the expected relay boundary.",
        );
      }
      if (health.status === "ok" && health.revision === revision) return health;
      failure = "Health does not yet match the tested release";
    }
    if (attempt + 1 < attempts) await sleep(5000);
  }
  throw new Error(`Deployed health verification failed: ${failure}.`);
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  const health = await verifyHealth({
    relayUrl: process.env.RELAY_URL,
    revision: process.env.EXPECTED_REVISION,
    environment: process.env.EXPECTED_ENVIRONMENT,
  });
  console.log(
    `Verified ${health.environment} relay at revision ${health.revision}`,
  );
}
