import { writeFile } from "node:fs/promises";

for (const key of [
  "CM_API_TOKEN",
  "CM_APP_ID",
  "CM_BUILD_ID",
  "RELEASE_BRANCH",
  "EXPECTED_REVISION",
])
  if (!process.env[key]) throw new Error(`Missing ${key}`);
if (!/^[a-f0-9]{24}$/.test(process.env.CM_BUILD_ID))
  throw new Error("Invalid source build ID");
async function api(path, body) {
  const response = await fetch(`https://codemagic.io/api/v3${path}`, {
    method: body ? "POST" : "GET",
    headers: {
      "x-auth-token": process.env.CM_API_TOKEN,
      Accept: "application/json",
      "Content-Type": "application/json",
    },
    body: body ? JSON.stringify(body) : undefined,
    redirect: "error",
    signal: AbortSignal.timeout(30000),
  });
  if (!response.ok)
    throw new Error(`Codemagic inspection HTTP ${response.status}`);
  return (await response.json()).data;
}
const source = await api(`/builds/${process.env.CM_BUILD_ID}`);
if (
  source.app_id !== process.env.CM_APP_ID ||
  source.workflow?.id !== "ios-release"
)
  throw new Error("Source build identity mismatch");
const number = String(
  source.artifacts?.find((artifact) => artifact.name.endsWith(".ipa"))
    ?.version_code ?? "",
);
if (!/^\d+(\.\d+)*$/.test(number))
  throw new Error("Source IPA has no valid build number");
console.log(
  `Inspecting existing Apple build ${number}; no new IPA will be built or uploaded.`,
);
const started = await api(`/apps/${process.env.CM_APP_ID}/builds`, {
  workflow_id: "ios-inspect",
  branch: process.env.RELEASE_BRANCH,
  environment: {
    variables: {
      EXPECTED_REVISION: process.env.EXPECTED_REVISION,
      INSPECT_BUILD_NUMBER: number,
    },
  },
});
if (!/^[a-f0-9]{24}$/.test(started.id ?? ""))
  throw new Error("Invalid inspection build ID");
console.log(`Accepted Apple inspection ${started.id}`);
for (let attempt = 0; attempt < 90; attempt++) {
  await new Promise((resolve) => setTimeout(resolve, 10000));
  const build = await api(`/builds/${started.id}`);
  if (
    build.id !== started.id ||
    build.app_id !== process.env.CM_APP_ID ||
    build.workflow?.id !== "ios-inspect"
  )
    throw new Error("Inspection identity mismatch");
  if (build.status === "finished") {
    if (build.commit?.hash !== process.env.EXPECTED_REVISION)
      throw new Error("Inspection revision mismatch");
    const artifact = build.artifacts?.find(
      (item) => item.name.split("/").pop() === "testflight-inspection.json",
    );
    if (
      !artifact?.short_lived_download_url ||
      new URL(artifact.short_lived_download_url).protocol !== "https:"
    ) {
      console.log(
        JSON.stringify({
          artifacts: build.artifacts?.map((item) => item.name),
        }),
      );
      if (attempt < 12) continue;
      throw new Error("Sanitized inspection artifact missing");
    }
    const response = await fetch(artifact.short_lived_download_url, {
      signal: AbortSignal.timeout(30000),
    });
    if (!response.ok)
      throw new Error(`Inspection artifact HTTP ${response.status}`);
    const report = await response.json();
    if (
      report.revision !== process.env.EXPECTED_REVISION ||
      report.buildNumber !== number ||
      !Array.isArray(report.builds)
    )
      throw new Error("Inspection report mismatch");
    const sanitized = {
      revision: report.revision,
      buildNumber: number,
      builds: report.builds.map((row) => ({
        version: row.version,
        processingState: row.processingState,
        expired: row.expired,
        usesNonExemptEncryption: row.usesNonExemptEncryption,
        uploadedDate: row.uploadedDate,
      })),
    };
    await writeFile(
      "testflight-inspection.json",
      JSON.stringify(sanitized, null, 2),
    );
    console.log(JSON.stringify(sanitized, null, 2));
    process.exit(0);
  }
  if (["failed", "canceled", "skipped", "timeout"].includes(build.status))
    throw new Error(`Apple inspection ${started.id} ended: ${build.status}`);
}
throw new Error(`Apple inspection ${started.id} timed out`);
