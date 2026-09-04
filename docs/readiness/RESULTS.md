# Production-readiness candidate — September 4, 2026

The release candidate is implemented and locally validated on `codex/production-readiness`. Production remains unchanged. Deployment acceptance still requires the live gates in [ROLLOUT.md](ROLLOUT.md); this report does not claim a deployed or production-load-tested result.

## What changed

Webhook admission now commits to Postgres before returning success. Callback IDs are unique, replay responses retain the original deadline, and queue rates survive restart or competing instances. One bounded dispatcher replaces volatile buffering, per-queue timers, per-portal processes, duplicated retries, and config caching. Owned database leases fence late results; retries, cooldowns, terminal failures, and batch isolation are durable. OAuth refreshes serialize across connections, metadata excludes credentials, configuration requires authentication, and database TLS verifies both trust and hostname.

The source/config footprint fell from 4,091 to 2,770 lines: **1,321 fewer lines (32.3%)**, counting `.ex`/`.exs` under `lib/` and `config/` against baseline `1838519`. Tests, migrations, audit artifacts, and runbooks are excluded from that comparison. Legacy test filenames were retained and their scenarios adapted to the new architecture.

Patched dependency versions and reviewed remaining matches are documented in [SECURITY.md](SECURITY.md). The final scan covers 47 packages: ten originally affected packages were upgraded or removed; three Cowlib matches remain with evidence-backed, version-scoped lack-of-exposure/mitigation reviews. These reviews expire October 4. This is not a zero-vulnerability claim.

## Verification

| Check | Result |
| --- | --- |
| Full suite | **68 tests, 0 failures** with the final patched dependency set |
| Application compilation | `MIX_ENV=test mix compile --warnings-as-errors` and production compilation passed |
| Formatting | `mix format --check-formatted` passed |
| Production release | Built successfully from a clean temporary build directory |
| Actual release smoke | Paused boot before migration; liveness 200 and readiness 503; signed admission 503; migration; active readiness 200; unauthenticated config and unsigned webhook 401; paused readiness 503; trusted database TLS accepted and untrusted CA rejected |
| Real database concurrency | 20 concurrent duplicate admissions produce one row; 10 independent claimants cannot multiply a daily allowance; 20 concurrent OAuth readers perform one refresh; killing an admitting process after success preserves the row |
| Failure coverage | Stale ownership, task watchdog/restart, multi-batch draining, newly arriving actions versus old quota, 401 refresh, 429 cooldown, transient errors, retry cap, invalid-batch isolation, expiry between claim/send, retention and configuration changes |
| Migration fixtures | Preserve active work; completed duplicate wins; latest historical queue rate retained; full initial daily cooldown; credential metadata scrubbed; repeat migration is a no-op |
| CI | Workflow added for Linux, Elixir 1.19.5 / OTP 28 and PostgreSQL 16; **not run remotely during this task** |

Local validation used PostgreSQL 14 for regression tests and an isolated PostgreSQL 15 server for final load, scale, and TLS release checks. Fake credentials and HTTP adapters prevented HubSpot traffic. Tests using separate committed connections exercise database contention; they are not a multi-host failover certification.

## Burst measurements

Both runs submitted **55,000 signed requests at concurrency 20**, verified every acknowledged callback was durable, replayed 100 requests without creating duplicates, and drained all 55,000 rows using simulated successful HubSpot responses.

| Local scenario | Admission rate | p95 | p99 | Drain |
| --- | ---: | ---: | ---: | ---: |
| 16 portals | 6,292 requests/s | 2.614 ms | 3.382 ms | 560 batches, 0.699 s |
| One portal/queue | 4,584 requests/s | 4.609 ms | 7.127 ms | 550 batches, 9.955 s across persisted rate intervals |

These are in-process signed Phoenix endpoint calls, not TCP/WAN or Render benchmarks. Dispatch measurements call the store with simulated 204 results and exclude OAuth, network latency, and the task scheduler. The concentrated run exposes queue-row contention and rate timing. Admission recorded six SQL telemetry events per action, including transaction commands. The old implementation was not run under the same harness, so these numbers do not establish a before/after speedup. The principal proven improvements are durability, bounded work, restart-safe limits, reduced code, and fewer routine logs.

Raw results: [16-portal burst](load-results.json), [single-portal burst](hot-portal-results.json), [release smoke](release-smoke-results.json), [dependency audit](dependency-audit.json).

## Migration scale

The synthetic historical-table rehearsal used **7.6 million rows and ten pre-cutover indexes**. All 42 pending fixtures survived. Migration took approximately **82 seconds**, including about 0.194 seconds of count verification. Database size grew from 2.62 GB to 3.35 GB; measured WAL upper bound was 666 MB; cumulative temporary writes were 2.88 GB. Temporary writes are not a peak-free-space requirement. Exact timing was recovered from query log timestamps because a reporting-only LSN codec error occurred after the migration and assertions; the reporting query has been corrected.

The data distribution, extra indexes, local machine, and PostgreSQL version differ from production. A verified restore of the actual production schema/data remains mandatory before choosing the maintenance window and storage headroom. See [scale results](scale-results.json), [fixture results](upgrade-results.json), and guarded scripts under `scripts/`.

## Remaining release gates

Require the exact candidate's remote CI; reconcile the unexplained historical migration and extra production indexes; rehearse a restored backup; verify TLS from Render; provision measured disk headroom; review current backlog deadlines and the conservative initial cooldown; then execute the paused cutover, real HubSpot smoke, and post-release observation. Verify daily-rate behavior through the next full due interval. No service deploy, migration, credential rotation, network change, push, or real callback send was performed here.

External HTTP delivery remains at least once: a server may accept a request before its response is lost. Unique admission and database fencing do not make an external side effect exactly once. Deduplication also has a finite retention horizon. Rollback after cutover is a paused forward fix; restarting the old dispatcher against new scheduling state is unsafe.
