# Offline cutover and rollback

This is a release procedure, not a deployment record. Candidate preparation changed no production service, database, credentials, domain, or network policy. Stop at any failed gate. Do not run the migration during a rolling overlap with the old dispatcher.

## Before scheduling

1. Merge/review the candidate and require its exact commit's Linux/PostgreSQL 16 CI to pass. Build a release with the validated Elixir 1.19.5 / OTP 28 toolchain. Render must use the release start command, not the previous `mix phx.server` command. Build: `./build.sh`; start: `_build/prod/rel/throttle/bin/throttle start`. The build never migrates.
2. Refresh Render evidence for service `srv-crfmturv2p9s73ct2b3g` and database `dpg-cr1mb6o8fa8c73aadmg0-a`: deployed SHA, instance count, health path, environment variable names, disk/free space, recent errors and rate-limit events. Baseline SHA was `1838519`, not proof of the current deployment. Do not print environment values.
3. Run `preflight.sql` through a secured, read-only production connection. Reconcile the extra migration `20240901233756` and out-of-band indexes against a schema-only export before release. Do not invent a no-op migration to hide unexplained schema drift. Resolve null/invalid callback identities, cross-queue duplicate identities, invalid rates, and expired backlog deliberately. The migration aborts on unsafe active queues or cross-queue callback conflicts.
4. Take a backup, verify restoration into an isolated database, and rehearse this exact migration against that restored schema/data. Local synthetic results are not a substitute for a restore test. The 7.6m-row rehearsal took approximately 82 seconds, grew the database by 727 MB, generated at most 666 MB of measured WAL, and recorded 2.88 GB of cumulative temporary writes. Temporary writes are not peak concurrent space. Size the maintenance window and disk capacity from the restored-data run plus a safety margin; the baseline 5 GB allocation should not be assumed sufficient. Provision space before starting. No index drops are included: most existing overlapping indexes had real scans.
5. Verify database TLS from the Render runtime. The URL hostname must match the certificate, or set `DATABASE_TLS_SERVER_NAME` to the certificate's verified service hostname when connecting through a private alias. System CA roots are the default; private CA files use `DATABASE_CA_CERT_PATH`. Never bypass peer or hostname verification. [Render connection guidance](https://render.com/docs/postgresql-creating-connecting) distinguishes internal routing and external SNI requirements.
6. Preserve the current encryption key. Validate both HubSpot app credentials, callback URL, and production signing secret without exposing them. Set a new config API bearer key for authorized clients, or leave that API closed. Review `SECURITY.md`, including the three version-scoped Cowlib applicability reviews. Identify legitimate external database clients before restricting the baseline broad allowlist.
7. Review initial rate cooldowns. The migration gives every historical queue a full configured interval before fresh work is eligible. This intentionally avoids granting a restart burst because old completion timestamps are unreliable. The baseline had 39 pending callbacks at 25/day and three at 5/day. Confirm current deadlines can accommodate the delay. Do not move due times earlier without authoritative last-dispatch evidence and an approved queue-specific adjustment.

## Cutover

1. Temporarily route webhook ingress through a controlled responder that returns `503` with `Retry-After: 30`. Verify the actual public webhook path does not return success. HubSpot should retry failed admission; monitor those retries and keep the window within its retry policy. This ingress change is part of the explicitly approved release, not candidate preparation.
2. Let the old admission buffers drain. Inspect only counts from the old `ActionBatcher` state (`buffer_size`, `queued_size`, length of `pending_flush`, and `flushing`) via an authorized runtime console; do not dump callback payloads. All counts must be zero and `flushing` false before replacement. If runtime inspection is unavailable, require equivalent observable flush evidence and reconcile admissions; do not assume a sleep proves durability.
3. Deploy the candidate **paused**: `THROTTLE_ADMISSION_ENABLED=false`, `THROTTLE_DISPATCH_ENABLED=false`, config API closed. Temporarily point Render's health check at `/api/live` so the paused release can replace the old one. `/api/live` checks process liveness only; `/api/health` must remain `503`. With dispatch disabled, Oban maintenance is also stopped, so the candidate can boot against the old schema. Verify the exact candidate SHA, every instance replaced, and no old dispatcher processes or old one-off jobs still running. Allow outstanding old HTTP requests to settle before migration.
4. Keep public ingress in maintenance. From the candidate release, run `_build/prod/rel/throttle/bin/throttle eval 'Throttle.Release.migrate()'`. Record timing and applied versions `20260904190000`, `20260904191000`, `20260904192000`, and `20260904193000`. The main cutover locks the action table with a five-second lock-acquisition timeout. A failure rolls back that migration's transaction; the separate credential-scrub migration may already be committed and should remain so. Retry only after resolving the cause.
5. Verify a valid unique callback index; pending counts reconcile with duplicates and expired work; each active action has a durable queue; initial due times and rates match the approved cooldown plan; no old `Throttle.ThrottleWorker` jobs remain runnable; credential keys are absent from token metadata. No real callback should have been sent by the paused candidate.
6. Enable admission and dispatch on the candidate while ingress remains gated. Confirm readiness `200`, the expected release SHA, and database connectivity. Set Render's normal health path to `/api/health`. Verify existing pending work respects its initial due times. Then restore webhook routing.
7. Use a disposable HubSpot workflow execution for the live smoke. Verify a signed request receives `200 BLOCK` with its persisted deadline, its callback ID exists exactly once, a replay neither creates a row nor changes the deadline, and configured delivery completes successfully. Check signed-session OAuth authorization/refresh for the test portal without exposing tokens. This sends real external actions and belongs only to the approved release.

## Observe and accept

During the first hour, compare Render CPU/memory, response status counts, callback errors and 429s with the baseline. Query durable pending age/deadline, terminal failures, portal leases, queue due times, and recent `completed_at` counts. Confirm arrivals continue to become durable under a realistic burst; successful rows advance at configured rates. Check daily-rate queues through their next due interval before claiming sustained production behavior. Record actual admission latency through the deployed endpoint; the local in-process benchmark excludes WAN latency and Render capacity.

Useful checks after migration:

```sql
SELECT queue_id, count(*) AS pending, min(inserted_at) AS oldest, min(expires_at) AS earliest_expiry
FROM action_executions WHERE NOT processed AND NOT permanently_failed GROUP BY queue_id;
SELECT count(*) FROM dispatch_portals WHERE lease_until < timezone('UTC',now());
SELECT count(*) FROM action_executions WHERE completed_at > timezone('UTC',now()) - interval '5 minutes';
SELECT last_failure_reason, count(*) FROM action_executions
WHERE NOT processed GROUP BY last_failure_reason;
```

Expired leases should recover within 180 seconds plus polling after a crashed task. Scheduler concurrency is bounded at 16; idle polling is 250 ms, with immediate draining after task completion. Look for persistent stale leases, repeated refresh failures, increasing callback age near expiration, or unexplained 503s. Any such condition pauses acceptance of the rollout until diagnosed.

## Rollback

Before migration, the old release may be restored only after reconciling any remaining RAM-buffered admissions. After migration, **do not restart the old dispatcher**: it ignores durable rate budgets and ownership. Safe rollback is an operational pause: gate ingress with retryable 503s, set both candidate flags false, use `/api/live` temporarily for the maintenance deployment, verify tasks and maintenance have stopped, and forward-fix while preserving accepted rows.

Schema rollback is deliberately not automated. Restoring the pre-cutover backup discards later admissions and completion evidence; it requires an explicit reconciliation plan for every accepted callback and any external completion already sent. Never run `mix ecto.reset`, bulk-delete pending rows, reset due times, or restore a stale backup as an unreviewed recovery step. Credentials removed from metadata are never recreated by a down migration.
