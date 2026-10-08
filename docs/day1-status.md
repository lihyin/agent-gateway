# Day 1 validation status

Day 1 implementation is ready for live validation. Its current iOS-only scope is not complete until production deployment, signed TestFlight distribution, physical iOS installation, and rollback checks pass.

## Implemented

- Health-only Cloudflare Worker, separate local/staging/production environments, no private-data routes.
- Generated native Android/iOS Flutter project with injectable configuration and a shell that offers no source access.
- Real Android release signing configuration with no debug-key fallback.
- Demo-agent and mock-provider health services; Dockerfile and Compose local stack.
- GitHub PR checks and manually dispatched production orchestration.
- Manually dispatched relay recovery with explicit version/revision validation, health verification, deployment evidence artifacts, and a shared production concurrency lock.
- Codemagic signed Android internal release, initial Android bootstrap artifacts, and iOS TestFlight workflows.
- v3 Codemagic API polling with revision/app/workflow/artifact verification, bounded waits, failed-build propagation, TestFlight post-processing checks, and sanitized release report.
- Production account/setup, API, and rollback documentation.

## Verified locally

- Formatting, lint, TypeScript checks, and configuration YAML parsing.
- Node tests covering Worker routes, adapter callback rejection, and orchestration completion/failure/identity handling.
- Worker dry-run build and adapter TypeScript build.
- Actual Wrangler local runtime health, mutating-health rejection, and disabled source routes.
- Flutter analysis and widget test.
- Docker Compose CLI configuration validation.

On October 8, 2026, the iOS-only delivery change passed `npm run check` (formatting, configuration parsing, lint, type checks, 10 Node tests, Worker dry-run build, and adapter build), Flutter analysis, and the mobile widget test. Mocked orchestration tests verify that only iOS is triggered, failed builds fail the release, and reports exclude credentials/artifact URLs. The added recovery workflow also passed YAML/configuration validation and formatting checks. These checks do not establish live deployment, recovery, or TestFlight delivery.

## Current delivery scope

GitHub production delivery deploys staging/production relays and runs only the Codemagic `ios-release` workflow. Android signing, distribution, and physical Android acceptance are deferred at the user's request; Android debug-build CI checks remain enabled. Android is not a blocker for the current iOS-only Day 1 scope.

## Pending acceptance evidence

- Successful aggregate production delivery (relay deployment has passed; mobile delivery remains incomplete).
- Successful use of the configured Apple signing identities, app record, and TestFlight group during the native release build.
- Successful signed iOS build and TestFlight distribution; native iOS builds require Codemagic.
- Physical iOS installation and launch with the expected revision.
- Production relay rollback/restoration (staging rollback/restoration has passed).

## First live delivery attempt

[Production delivery 37746403785](https://github.com/lihyin/agent-gateway/actions/runs/37746403785) passed release verification and deployed staging version `e867964e-3a48-4bfa-8da4-28105d336fb1` for commit `f9e1f91241134fb7276149dc2fdd3dbe67362caf`. Its immediate health check received an HTML response before the endpoint became available, so the workflow stopped before production/mobile delivery. A subsequent live check verified staging health, the exact revision, and disabled source access. Health verification now uses bounded propagation retries and still rejects mismatched service/environment or enabled source access immediately. No production or TestFlight completion is claimed for this attempt.

## Live relay and staging recovery evidence

[Production delivery 37746895019](https://github.com/lihyin/agent-gateway/actions/runs/37746895019) passed verification, deployed both relays, and verified commit `c681c1d6f74ce8174c7f825dc0117253cbc65e15` with source access disabled:

- Staging: `https://agent-gateway-relay-staging.agentbrain.workers.dev`, version `8b4d7b4e-2749-4afc-9144-6396f0da0552`.
- Production: `https://agent-gateway-relay-production.agentbrain.workers.dev`, version `0cfc6e15-a683-4c82-a88a-de6536169e45`.

Codemagic accepted iOS build `6ac74dfbde4f6899ca0d1ec6`. The orchestrator received HTML from the first status request and correctly failed rather than claiming delivery. [Inspection 37747495109](https://github.com/lihyin/agent-gateway/actions/runs/37747495109) subsequently confirmed the matching app/workflow/commit but a failed build, no IPA artifacts, and no completed TestFlight processing. Requests now explicitly accept JSON and tolerate a bounded initial non-JSON status window; persistent invalid responses remain failures.

[Staging rollback 37747525379](https://github.com/lihyin/agent-gateway/actions/runs/37747525379) activated the earlier verified `f9e1f91` version and passed health verification. [Staging restoration 37747618204](https://github.com/lihyin/agent-gateway/actions/runs/37747618204) restored version `8b4d7b4e-2749-4afc-9144-6396f0da0552` and verified `c681c1d`. Both recovery runs succeeded and recorded deployment artifacts.

No Gmail, push-provider, pairing, encryption, connector, or approval features have been implemented in Day 1. Later milestones remain pending.

## GitHub CI evidence

The current delivery repository is the user-owned fork `lihyin/agent-gateway`, with default branch `relay-architecture`. Its `production` environment restricts deployments to that branch and has the confirmed Cloudflare account ID, Codemagic app ID, and staging/production `agentbrain.workers.dev` origins. Release and recovery workflows are registered. Fork environment API tokens and Codemagic repository access must be configured directly by the owner; fork creation does not transfer secrets. Earlier CI evidence below belongs to the original repository.

[CI run 37741823009](https://github.com/DeepShareAI/agent-gateway/actions/runs/37741823009) passed for iOS-only delivery commit `edee142c92780615099fd0af11762a8cfb836177`. Node verification/builds, the 10 Node tests, Docker Compose startup and health/private-route smoke checks, Flutter formatting/analysis/tests, and the Android debug APK build all passed. Both configured `agentbrain.workers.dev` health endpoints returned HTTP 404 during the October 8 readiness check; no live relay deployment or TestFlight delivery is claimed.

[CI run 37289995185](https://github.com/DeepShareAI/agent-gateway/actions/runs/37289995185) passed for implementation commit `b67e90a`. Both Node and mobile jobs completed successfully, including Compose container startup and health/private-route smoke checks, Node verification/builds, Flutter analysis/tests, and the Android debug APK build. Docker is still unavailable as a local daemon on this Windows machine, but the local stack has been exercised on the Linux CI runner.

The relay container initially failed because package-manifest copies created root-owned workspace directories. Explicit ownership correction before switching to the non-root user fixed Wrangler's temporary-directory access. The successful run validates that correction. Signed release builds, iOS builds, live provider deployment, tester distribution, and physical installation are separate pending checks; debug-build success does not establish them.
