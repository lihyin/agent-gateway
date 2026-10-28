# PairingRegistry and automatic routing

Implemented in this checkout; deployment and physical-device validation remain
separate release steps. PairingRegistry is the sole transport authority. There is
no PAIRING_CONFIG fallback and no RELAY_ROUTE client setting.

The registry stores public pair records, encrypted push destinations, monotonic
update timestamps, per-pair rate counters and retired-epoch tombstones. It never
stores Gmail credentials, payload private keys, request/result content or approvals.

The phone self-registers its device-signed pair during pairing and opts into
notifications once. It updates its signed push registration automatically while
active and on resume. The relay verifies the agent's signature and current epoch
before resolving that pair's destination. Registration proofs expire in 30 seconds;
stored destinations do not expire daily. Token refresh requires the phone to run.

Re-pairing clears the old destination and retires its epoch. Unpairing is a signed
online revocation; disabling notifications clears the destination while preserving
its update high-water mark. Old updates and retired pair registrations fail closed.
One device cannot replace a different device's agent ID. Delivery attempts,
including retries, are capped at ten per pair per minute. Open signup still needs
account-wide abuse controls for a public deployment.

Deploy matching relay, agent client and app versions together. Apply the existing
v3-pairing-registry migration/binding, configure RELAY_ROUTING_KEY and APNs secrets,
and remove the unused PAIRING_CONFIG secret. The new tables initialize inside the
existing registry class. With no existing users, there is no legacy migration path.
Routing-key rotation requires phones to reopen and register their destinations.
See [security](../../docs/security.md), [API](../../docs/api.md) and
[setup](../../docs/remote-delivery.md).
