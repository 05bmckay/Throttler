# Project guidance

Updated September 4, 2026 for the production-readiness candidate. This document describes the candidate, not proof of deployment. Consult `docs/readiness/RESULTS.md` and `ROLLOUT.md` for evidence and release gates.

## Structure

- `lib/throttle/admission.ex`: synchronous transaction, unique callback identity, durable queue configuration. Acknowledge only after commit.
- `lib/throttle/dispatch_store.ex`: database-owned rate reservations, portal leases, retries, expiration, fencing.
- `lib/throttle/dispatcher.ex`: bounded scheduler (16 tasks); `dispatch_supervisor.ex` restarts it and its tasks together.
- `lib/throttle/delivery.ex`, `hubspot_client.ex`, `http.ex`: one HTTP attempt, optional 401 refresh, durable result transition. Test adapter must never fall through to network.
- `lib/throttle/oauth_manager.ex`: encrypted credentials, metadata allowlist, database-serialized refresh.
- `lib/throttle_web/`: API-only Phoenix, signed webhooks, authenticated config, OAuth state, readiness.
- `config/runtime.exs`: authoritative production config, TLS verification, explicit admission/dispatch flags.
- `priv/repo/migrations/`: forward-only durable-dispatch cutover after stopping the old runtime.
- `scripts/`: guarded, synthetic local load/migration rehearsals.
- `assets/` and `throttler-ratelimiter/`: legacy/separate concerns, not part of release asset compilation.

## Rules

Preserve unrelated work. Do not print credentials, tokens, callback bodies, or database URLs. Use metadata-only production inspection. Do not deploy or change production based solely on green local tests. Reconcile the exact deployed SHA and schema before release: production historically contained migration 20240901233756 and extra indexes absent from this repository.

The canonical queue ID is `queue:{portal}:{workflow}:{action}:{index}`. Queue rate is a persisted burst allowance, not even spacing. Fresh arrivals cannot spend an old reservation. Retries do not create fresh allowance. Lease ownership must be checked before HTTP and when applying results; no local-only cache/timer may override persisted state. External HTTP delivery remains at least once.

Use `mix test`, `mix format --check-formatted`, and `MIX_ENV=test mix compile --warnings-as-errors`. Test configuration imports last so Oban queues remain disabled. Real concurrency tests use separate committed database connections and clean up only their own identities. Legacy test filenames are retained with scenarios adapted to the durable architecture. Historical audit probes belong to baseline commit 1838519 and are not candidate tests.

Build via `./build.sh`; migrations never run during an overlapping build. Production defaults both admission and dispatch off. Readiness is intentionally 503 when paused. Follow `docs/readiness/ROLLOUT.md`; never roll back to old queue processes against live new scheduling state.
