# Agent Gateway website

Minimal static product website with overview, contact, terms, and privacy pages.
The legal pages and downloadable copies are generated from the repository-root
`TERMS_OF_SERVICE.txt` and `PRIVACY_POLICY.txt` files.

Build from the repository root:

```sh
node website/build.mjs
```

Deploy to a separate Cloudflare Worker:

```sh
npx wrangler deploy --config website/wrangler.toml
```

The generated website has no application JavaScript, forms, cookies, or external
font requests. Cloudflare serves the site and may add network or performance
measurement under the deployment's settings.

Public legal pages are https://gateway.zerobox.ai/privacy/ and
https://gateway.zerobox.ai/terms/. Both are dedicated, unauthenticated HTML pages,
with homepage navigation, footer, and Gmail disclosure links. Their text comes
from the root policies, including the effective date and Zerobox privacy contact.
The mobile app exposes these same links on its home screen and before Gmail
OAuth. Google domain ownership and OAuth Branding URL configuration must be
verified separately in the Google project; a working page does not prove those
console settings or completion of OAuth verification.
