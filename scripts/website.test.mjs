import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = fileURLToPath(new URL("../", import.meta.url));
execFileSync(process.execPath, ["website/build.mjs"], { cwd: root });
const read = (name) =>
  readFileSync(new URL(`../website/dist/${name}`, import.meta.url), "utf8");

test("public homepage exposes dedicated HTML legal pages without a sign-in gate", () => {
  const home = read("index.html");
  assert.match(home, /href="\/privacy\/">Privacy Policy<\/a>/);
  assert.match(home, /href="\/terms\/">Terms of Use<\/a>/);
  for (const [route, source] of [
    ["privacy", "PRIVACY_POLICY.txt"],
    ["terms", "TERMS_OF_SERVICE.txt"],
  ]) {
    const html = read(`${route}/index.html`);
    assert.match(html, /<article class="legal">/);
    assert.match(html, /Agent Gateway/);
    assert.match(html, /Zerobox/);
    assert.match(html, /hello@zerobox\.ai/);
    assert.doesNotMatch(
      html,
      /<iframe|<embed|<object|\[(?:OPERATOR LEGAL NAME|PRIVACY CONTACT EMAIL)\]/i,
    );
    const original = readFileSync(
      new URL(`../${source}`, import.meta.url),
      "utf8",
    ).trim();
    assert.equal(read(source).trim(), original);
  }
});
