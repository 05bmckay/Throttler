# Throttle

Durable, rate-limited HubSpot workflow callbacks using Phoenix, PostgreSQL, and Finch. A signed webhook returns `200 BLOCK` only after its callback has committed to PostgreSQL. Replays reuse the same row and original deadline. Completed callbacks return `SUCCESS`; terminal or expired callbacks return `FAIL_CONTINUE`.

```text
Verified webhook → Admission transaction → action_executions + dispatch_queues
                                             ↓
                            bounded Dispatcher → owned portal lease
                                             ↓
                                   OAuth → HubSpot callback
                                             ↓
                              owner-checked completion / retry
```

Postgres owns queue budgets, due times, retries, and portal leases. One small dispatcher schedules at most 16 tasks per instance; portal ownership prevents competing instances from concurrently delivering for the same portal. There are no per-queue or per-portal GenServers, volatile admission buffers, or config cache. Oban runs expiry and retention maintenance only.

## Rate and delivery contract

A due queue reserves up to its configured allowance from already-pending actions. Reservations drain in batches of at most 100. New arrivals wait for the next interval; retries retain their original reservation. Rate configuration updates preserve the current reservation and next due time. Explicit inputs on a newly accepted webhook become the queue's current configuration.

Configured rates are ceilings, not throughput guarantees; HTTP latency and upstream limits can reduce delivery speed. Portal-wide 429 cooldowns persist across restarts. Transient failures use one durable retry schedule, ending after 20 failed attempts or callback expiration. Invalid multi-item batches are isolated into single-item requests before permanently failing individual callbacks. Tasks have a 120-second watchdog and 180-second database lease. A late owner cannot change a replacement owner's rows.

External delivery is **at least once**: HubSpot may accept a request just before the process loses the response or crashes. Database fencing prevents stale local writes but cannot revoke a request already accepted by HubSpot. Callback identities remain unique until terminal retention removes them; retention is at least 35 days from insertion and recorded completion, and seven days past the callback deadline.

## Development and verification

Validated locally with Elixir 1.19.5 / OTP 28 and PostgreSQL 14/15. CI targets PostgreSQL 16; its remote run is a release gate.

```sh
mix deps.get
mix ecto.setup
mix phx.server
mix test
mix format --check-formatted
MIX_ENV=test mix compile --warnings-as-errors
```

`DEV_DATABASE_URL` defaults to a local `throttle_dev` database. Remote development databases require a trusted TLS certificate. Test data uses `TEST_DATABASE_URL`, defaulting to local `throttle_test`. Tests use fake HTTP responses and never contact HubSpot. Local dispatch defaults off; enable `:dispatch_enabled` deliberately for a development integration run.

## Production configuration

| Variable | Purpose |
| --- | --- |
| `DATABASE_URL` | PostgreSQL URL with a hostname matching its TLS certificate |
| `DATABASE_TLS_SERVER_NAME` | Optional verified certificate hostname when connecting through a private alias |
| `DATABASE_CA_CERT_PATH` | Optional private CA file; otherwise use system trust roots |
| `SECRET_KEY_BASE` | Phoenix session signing secret |
| `ENCRYPTION_KEY` | Existing Base64-encoded 32-byte key; preserve it across deploys |
| `HUBSPOT_CLIENT_ID`, `HUBSPOT_CLIENT_SECRET` | App credentials and webhook verification secret |
| `HUBSPOT_REDIRECT_URI` | Registered OAuth callback URL |
| `THROTTLE_ADMISSION_ENABLED` | Must be `true` to accept callbacks; production defaults off |
| `THROTTLE_DISPATCH_ENABLED` | Must be `true` to deliver callbacks; production defaults off |
| `THROTTLE_CONFIG_API_KEY` | Bearer key of at least 32 bytes; absent means config API closed |
| `HUBSPOT_BLOCK_EXPIRATION_DURATION` | Default `P4W`, maximum callback blocking horizon |
| `BASE_URL`, `PORT` | Public hostname and listener port |
| `POOL_SIZE` | Default 20, capped at 20 per instance |

TLS peer and hostname verification are required. Do not restore `verify_none`. Successful requests log at debug while failures remain visible; request and database telemetry remain enabled. Sensitive OAuth metadata is allowlisted and credential fields are encrypted.

## API

- `POST /api/hubspot/action`: HubSpot signature verification, durable admission, replay-safe response; maintenance/database failure returns retryable `503`.
- `GET /api/live`: process liveness for the documented paused cutover only.
- `GET /api/health` and `/`: readiness; `200` requires admission, dispatcher, database, and candidate schema. Paused state returns `503`.
- `POST /api/config` and `GET /api/config/:portal_id/:action_id`: require `Authorization: Bearer <THROTTLE_CONFIG_API_KEY>`.
- `GET /api/oauth/authorize` and `/api/oauth/callback`: signed-session OAuth state and encrypted tokens; refreshes serialize using database row locks.

Example config JSON: `{"portal_id":12345,"action_id":"67890","max_throughput":10,"time_period":1,"time_unit":"seconds"}`.

## Release

`./build.sh` compiles an API-only release. It does **not** migrate the database. Start with `_build/prod/rel/throttle/bin/throttle start`; use the release's `eval 'Throttle.Release.migrate()'` only during the offline cutover described in [ROLLOUT.md](docs/readiness/ROLLOUT.md).

Read [candidate results](docs/readiness/RESULTS.md) and the [September 4 audit](docs/audits/2026-09-04/AUDIT.md) before deploying. This migration is incompatible with an overlapping old dispatcher and deliberately forward-only. Existing queues receive a conservative full-interval initial cooldown.
