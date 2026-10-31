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

The website has no JavaScript, forms, analytics, cookies, or external font requests.
Cloudflare may process network information when serving the website.
Set the operator and private privacy contact in the root policy before publication.
