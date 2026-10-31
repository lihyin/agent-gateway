import { readFile, mkdir, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = fileURLToPath(new URL("../", import.meta.url));
const out = path.join(root, "website/dist");
await mkdir(out, { recursive: true });
const escape = (value) =>
  value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
const links = [
  ["/", "Overview"],
  ["/contact/", "Contact"],
  ["/terms/", "Terms"],
  ["/privacy/", "Privacy"],
];
const repo = "https://github.com/lihyin/agent-gateway";
function page(title, route, body, description) {
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="description" content="${escape(description)}"><meta name="theme-color" content="#ffffff"><title>${title} — Agent Gateway</title><link rel="stylesheet" href="/style.css"><link rel="icon" href="/icon.svg" type="image/svg+xml"></head>
<body><a class="skip" href="#main">Skip to content</a><header><a class="brand" href="/" aria-label="Agent Gateway home"><img class="mark" src="/icon.svg" alt="" width="34" height="34">Agent Gateway</a><nav aria-label="Main navigation">${links.map(([url, label]) => `<a href="${url}"${route === url ? ' aria-current="page"' : ""}>${label}</a>`).join("")}</nav></header>
<main id="main">${body}</main><footer><span>Agent Gateway by Zerobox · Your information. Your decision.</span><div>${links
    .slice(1)
    .map(([url, label]) => `<a href="${url}">${label}</a>`)
    .join("")}<a href="${repo}">GitHub ↗</a></div></footer></body></html>`;
}
const overview = `<section class="hero"><p class="eyebrow">A personal gateway for your agent</p><h1>A little context.<br><em>On your terms.</em></h1><p class="lead">Let Muse request the Gmail information it needs. Review what leaves your phone, and decide what to share.</p><div class="actions"><a class="button" href="#how-it-works">See how it works <span aria-hidden="true">↓</span></a><a class="text-link" href="${repo}">Explore the project ↗</a></div><p class="small">Built for iPhone. Available through configured beta deployments.</p></section>
<section class="flow" id="how-it-works" aria-labelledby="flow-title"><div class="section-heading"><p class="eyebrow">From request to decision</p><h2 id="flow-title">You stay in the loop.</h2></div><ol><li><span class="number">01</span><h3>Pair your agent</h3><p>Connect Muse using a one-time code. Your phone and agent establish their pairing.</p></li><li><span class="number">02</span><h3>Review the request</h3><p>Open the app, authorize Gmail access, and review a limited, filtered preview.</p></li><li><span class="number">03</span><h3>Choose what to share</h3><p>Allow or deny disclosure. Approved information returns encrypted to your paired agent.</p></li></ol></section>
<section class="principles"><div><p class="eyebrow">Designed around your control</p><h2>Useful access.<br>Clear boundaries.</h2></div><div class="details"><article><h3>Credentials stay on your phone</h3><p>Gmail credentials and device private keys remain on your device. The relay transports encrypted requests and results.</p></article><article><h3>Read-only Gmail access</h3><p>The current app retrieves selected email metadata and snippets. It does not send, modify, or delete your mail.</p></article><article><h3>A decision before disclosure</h3><p>Review each preview and any saved approval rules. Filtering is best effort, so check sensitive information before sharing.</p></article></div></section>
<section class="closing"><p class="eyebrow">Open project. Human contact.</p><h2>Want to know more?</h2><p>Read the source, ask a question, or learn how your information is handled.</p><a class="text-link" href="/contact/">Get in touch <span aria-hidden="true">↗</span></a></section>`;
await writeFile(
  path.join(out, "index.html"),
  page(
    "Overview",
    "/",
    overview,
    "Agent Gateway lets you review and approve Gmail information requested by your paired Muse agent, directly on your iPhone.",
  ),
);
const contact = `<section class="page-intro"><p class="eyebrow">We’re listening</p><h1>Get in touch.</h1><p class="lead">Questions, feedback, or a problem with Agent Gateway? Start here.</p></section><section class="contact-list"><article><h2>Product & technical support</h2><p>Report a bug, suggest an improvement, or ask about setup on the project’s GitHub issue tracker.</p><a class="text-link" href="${repo}/issues">Open an issue ↗</a><p class="small">Public issues are visible to everyone. Never include email content, credentials, tokens, private keys, or pairing codes.</p></article><article><h2>Privacy & data requests</h2><p>Contact Zerobox for questions about personal information or deletion requests.</p><a class="text-link" href="mailto:hello@zerobox.ai">hello@zerobox.ai ↗</a></article><article><h2>Running another deployment?</h2><p>Contact the operator of your deployment for account, service, and data requests specific to that service.</p></article></section>`;
await mkdir(path.join(out, "contact"), { recursive: true });
await writeFile(
  path.join(out, "contact/index.html"),
  page(
    "Contact",
    "/contact/",
    contact,
    "Contact Agent Gateway for support, product feedback, and privacy questions.",
  ),
);
for (const [file, route, title] of [
  ["TERMS_OF_SERVICE.txt", "terms", "Terms of service"],
  ["PRIVACY_POLICY.txt", "privacy", "Privacy policy"],
]) {
  const text = (await readFile(path.join(root, file), "utf8")).trim();
  const paragraphs = text.split(/\r?\n\s*\r?\n/).slice(1);
  const content = paragraphs
    .map((part) => {
      const normalized = part.replace(/\r?\n/g, " ");
      if (/^\d+\. /.test(normalized)) return `<h2>${escape(normalized)}</h2>`;
      return `<p>${escape(normalized).replace(/https:\/\/[^\s<]+/g, (url) => `<a href="${url}">${url}</a>`)}</p>`;
    })
    .join("\n");
  await mkdir(path.join(out, route), { recursive: true });
  await writeFile(
    path.join(out, route, "index.html"),
    page(
      title,
      `/${route}/`,
      `<article class="legal"><p class="eyebrow">Agent Gateway</p><h1>${title}</h1>${content}<a class="text-link download" href="/${file}">Download as plain text ↓</a></article>`,
      `${title} for the Agent Gateway application and relay service.`,
    ),
  );
  await writeFile(path.join(out, file), text + "\n");
}
await writeFile(
  path.join(out, "404.html"),
  page(
    "Page not found",
    "",
    '<section class="page-intro"><p class="eyebrow">404</p><h1>Nothing here.</h1><p class="lead">This page may have moved.</p><a class="button" href="/">Back to overview →</a></section>',
    "Page not found.",
  ),
);
await writeFile(
  path.join(out, "style.css"),
  await readFile(path.join(root, "website/style.css"), "utf8"),
);
await writeFile(
  path.join(out, "icon.svg"),
  await readFile(path.join(root, "mobile/assets/brand/app-icon.svg"), "utf8"),
);
await writeFile(
  path.join(out, "_headers"),
  "/*\n  X-Content-Type-Options: nosniff\n  Referrer-Policy: strict-origin-when-cross-origin\n  Content-Security-Policy: default-src 'none'; style-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'\n  Permissions-Policy: camera=(), microphone=(), geolocation=()\n",
);
console.log("Built Agent Gateway website: website/dist");
