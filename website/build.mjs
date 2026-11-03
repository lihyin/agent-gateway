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
  ["/terms/", "Terms of Use"],
  ["/privacy/", "Privacy Policy"],
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
const overview = `<section class="hero"><p class="eyebrow">A personal gateway for your agent</p><h1>Protect your Gmail<br><em>from Muse.</em></h1><p class="lead">Let Muse request the Gmail information it needs. Preview a result first, or allow one-time sharing. You decide what leaves your phone.</p><div class="actions"><a class="button" href="#how-it-works">See how it works <span aria-hidden="true">↓</span></a><a class="text-link" href="${repo}">Explore the project ↗</a></div><p class="small">Built for iPhone. Available through configured beta deployments.</p><aside class="legal-note" aria-label="Gmail access and privacy"><strong>Before you connect Gmail</strong><p>Agent Gateway by Zerobox uses Gmail access for bounded searches of selected message details and to send email composed by Muse and approved by you. Gmail tokens stay on your device. Sharing results with Muse and sending email require separate approval. Outgoing email goes directly to Gmail after full review and device authentication.</p><p>Read our <a href="/privacy/">Privacy Policy</a> and <a href="/terms/">Terms of Use</a> for data access, sharing, retention, and deletion details.</p></aside></section>
<section class="flow" id="how-it-works" aria-labelledby="flow-title"><div class="section-heading"><p class="eyebrow">From request to decision</p><h2 id="flow-title">You stay in the loop.</h2></div><ol><li><span class="number">01</span><h3>Pair your agent</h3><p>Connect Muse using a one-time code. Your phone and agent establish their pairing.</p></li><li><span class="number">02</span><h3>Choose how to respond</h3><p>Preview retrieves a filtered result for review. Allow retrieves and shares once without showing a preview. Deny rejects the request without fetching email.</p></li><li><span class="number">03</span><h3>Stay in control</h3><p>Approved information returns encrypted to your paired agent. Disconnect Gmail, unpair Muse, or reset saved approvals when needed.</p></li></ol></section>
<section class="principles"><div><p class="eyebrow">Designed around your control</p><h2>Useful access.<br>Clear boundaries.</h2></div><div class="details"><article><h3>Credentials stay on your phone</h3><p>Gmail credentials and device private keys remain on your device. The relay transports encrypted requests and results.</p></article><article><h3>Review before sending</h3><p>Read selected email metadata and snippets, or review plain-text email composed by Muse with To, Cc, and Bcc. Allow or decline the complete message and authenticate before sending through Gmail. The app does not modify or delete existing mail, upload attachments, or save Gmail drafts.</p></article><article><h3>A decision before disclosure</h3><p>Choose Preview if you want to inspect the result before sharing. Filtering is best effort. Google Workspace data is not used to develop, improve, or train non-personalized AI or machine-learning models.</p></article></div></section>
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
const contact = `<section class="page-intro"><p class="eyebrow">We’re listening</p><h1>Get in touch.</h1><p class="lead">Questions, feedback, or a problem with Agent Gateway? Start here.</p></section><section class="contact-list"><article><h2>Product & technical support</h2><p>Report a bug, suggest an improvement, or ask about setup on the project’s GitHub issue tracker.</p><a class="text-link" href="${repo}/issues">Open an issue ↗</a><p class="small">Public issues are visible to everyone. Never include email content, credentials, tokens, private keys, or pairing codes.</p></article><article><h2>Privacy & data requests</h2><p>Contact Zerobox for questions about personal information or deletion requests.</p><a class="text-link" href="mailto:hello@zerobox.ai">hello@zerobox.ai ↗</a></article></section>`;
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
  ["TERMS_OF_SERVICE.txt", "terms", "Terms of Use"],
  ["PRIVACY_POLICY.txt", "privacy", "Privacy Policy"],
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
