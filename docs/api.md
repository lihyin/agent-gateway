# Day 1 API

## Relay

`GET /health` returns HTTP 200 JSON with `status: "ok"`, `service: "agent-gateway-relay"`, `environment`, `revision`, and `sourceAccessEnabled: false`. Responses use `Cache-Control: no-store`. GitHub Actions supplies the tested commit as `RELEASE_SHA` during deployment.

Other methods on `/health` return HTTP 405 with `Allow: GET`. All other routes return HTTP 404, including `/v1/requests`, `/v1/results`, and OAuth paths. There are no source credentials, push calls, pairing routes, payload decryption, or authorization APIs in the foundation.

## Local development services

The demo agent exposes `GET /health` with `callbackEnabled: false`; unfinished callbacks return HTTP 404 and retain no request bodies. Mock providers expose health and return HTTP 501 for unfinished operations. These services are local scaffolding; no provider integration is implemented.

## Protocol v1 design

Closed request, result, envelope, context, route, acknowledgment, and error schemas
are in [protocol/](../protocol/README.md). The selected standard nested JOSE
algorithms and cross-runtime fixture are documented in
[ADR 002](crypto-design.md). These contracts do not enable relay endpoints;
pairing, route issuance, persistent replay protection, and forwarding remain
separate implementation gates.
