import { pathToFileURL } from "node:url";

export async function requireTransportConfig({
  accountId,
  token,
  environment,
  fetchImpl = fetch,
}) {
  if (!accountId || !token || !["staging", "production"].includes(environment))
    throw new Error(
      "Cloudflare credentials and a valid target environment are required",
    );
  const worker = `agent-gateway-relay-${environment}`;
  const response = await fetchImpl(
    `https://api.cloudflare.com/client/v4/accounts/${encodeURIComponent(accountId)}/workers/scripts/${worker}/settings`,
    {
      headers: { Authorization: `Bearer ${token}`, Accept: "application/json" },
      redirect: "error",
      signal: AbortSignal.timeout(30000),
    },
  );
  if (!response.ok)
    throw new Error(
      `${environment}: Worker settings returned HTTP ${response.status}`,
    );
  const payload = await response.json();
  if (!payload.success || !Array.isArray(payload.result?.bindings))
    throw new Error(`${environment}: invalid Worker settings response`);
  const bindings = new Map(
    payload.result.bindings.map((binding) => [binding.name, binding]),
  );
  const privateNames = ["RELAY_ROUTING_KEY", "APNS_PRIVATE_KEY"];
  const publicNames = [
    "APNS_KEY_ID",
    "APNS_TEAM_ID",
    "APNS_TOPIC",
    "APNS_ENVIRONMENT",
  ];
  const missing = [...privateNames, ...publicNames].filter(
    (name) => !bindings.has(name),
  );
  if (missing.length)
    throw new Error(
      `${environment}: missing Worker bindings: ${missing.join(", ")}`,
    );
  const unsafe = privateNames.filter(
    (name) => bindings.get(name).type !== "secret_text",
  );
  if (unsafe.length)
    throw new Error(
      `${environment}: these bindings must be Secrets: ${unsafe.join(", ")}`,
    );
  const invalid = publicNames.filter((name) => {
    const binding = bindings.get(name);
    return (
      binding.type !== "secret_text" &&
      (binding.type !== "plain_text" ||
        typeof binding.text !== "string" ||
        !binding.text.trim())
    );
  });
  if (invalid.length)
    throw new Error(
      `${environment}: invalid Worker binding types or empty values: ${invalid.join(", ")}`,
    );
  // Return names only. Never print or persist the API response or binding values.
  return [...privateNames, ...publicNames];
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  await requireTransportConfig({
    accountId: process.env.CLOUDFLARE_ACCOUNT_ID,
    token: process.env.CLOUDFLARE_API_TOKEN,
    environment: process.env.TARGET_ENVIRONMENT,
  });
  console.log(
    `${process.env.TARGET_ENVIRONMENT}: required transport Secrets/Variables are configured.`,
  );
}
