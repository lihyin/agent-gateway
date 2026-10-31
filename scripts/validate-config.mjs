import { readFileSync } from "node:fs";
import { parseDocument } from "yaml";

for (const path of [
  "compose.yaml",
  "codemagic.yaml",
  ".github/workflows/ci.yml",
  ".github/workflows/release.yml",
  ".github/workflows/relay-recovery.yml",
  ".github/workflows/codemagic-inspect.yml",
  ".github/workflows/testflight.yml",
]) {
  const document = parseDocument(readFileSync(path, "utf8"));
  if (document.errors.length)
    throw new Error(
      `${path}: ${document.errors.map((error) => error.message).join("; ")}`,
    );
  console.log(`${path}: valid YAML`);
}

const codemagic = parseDocument(readFileSync("codemagic.yaml", "utf8")).toJS();
// Dashboard transport variables must survive every repository-managed deployment.
const wranglerTopLevel = readFileSync("relay/wrangler.toml", "utf8").split(
  /\r?\n\[/,
)[0];
if (!/^keep_vars\s*=\s*true\s*$/m.test(wranglerTopLevel))
  throw new Error("relay/wrangler.toml must set top-level keep_vars = true");
for (const path of [
  ".github/workflows/release.yml",
  ".github/workflows/relay-recovery.yml",
]) {
  const commands = readFileSync(path, "utf8")
    .split(/\r?\n/)
    .filter((line) => /\bnpx wrangler deploy\b/.test(line));
  if (
    !commands.length ||
    commands.some((line) => !line.includes("--keep-vars"))
  )
    throw new Error(
      `${path}: every relay deployment must explicitly use --keep-vars`,
    );
}
console.log(
  "Relay deploys preserve dashboard variables via config and CLI flags",
);
const bundleId =
  codemagic.workflows["ios-release"].environment.ios_signing.bundle_identifier;
const project = readFileSync(
  "mobile/ios/Runner.xcodeproj/project.pbxproj",
  "utf8",
);
const identifiers = [
  ...project.matchAll(/PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);/g),
].map((match) => match[1]);
if (
  identifiers.length !== 6 ||
  identifiers.filter((id) => id === bundleId).length !== 3 ||
  identifiers.filter((id) => id === `${bundleId}.RunnerTests`).length !== 3
) {
  throw new Error(
    "iOS project bundle identifiers must match Codemagic signing for all configurations",
  );
}
console.log(`iOS signing bundle identifier: ${bundleId}`);
