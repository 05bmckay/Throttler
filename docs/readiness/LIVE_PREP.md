# Live rollout preparation — September 4, 2026

Status: **restore rehearsal passed; cutover not yet cleared**. Application candidate `ec3c6d3` remains local on `codex/production-readiness`. This preparation created a Render backup and performed read-only production inspection. No production deploy, migration, ingress change, environment update, disk resize, or real callback smoke was performed.

## Verified production snapshot

- Service `srv-crfmturv2p9s73ct2b3g`, deployment `dep-dac80pm10ojc73ehaos0`, live SHA `1838519b61ac8ce5f540e2632513486b9890f4df`.
- One standard instance in Ohio. Git branch `main`; automatic deployment disabled; maintenance disabled; no configured health-check path. Build `./build.sh`; current start command `PORT=10000 mix phx.server`.
- Database `dpg-cr1mb6o8fa8c73aadmg0-a`: PostgreSQL 16, `pro_4gb`, 5 GB disk, no high availability. External network allowlist remains broad; no access changes were made.
- Current database size was 3,015,212,055 bytes. The read-only preflight counted 7,586,419 actions, 7,091 pending, no expired pending callbacks, no empty/null callback IDs, no cross-queue callback conflicts, and 3,469 historical duplicate identity groups. A later shape check found no malformed active rate strings. Counts change while production runs and these READ COMMITTED statements are not a single snapshot.
- External database TLS passed hostname and certificate verification from this Mac. This does **not** verify the Render runtime's private database route.
- Render SSH failed with `Permission denied (publickey)`; the local SSH agent has no identities. Runtime buffer inspection and private-route TLS verification remain pending. No SSH/account configuration was changed.

[One-hour metrics](live-metrics-baseline.json), sampled each minute from 21:47–22:47 UTC: service CPU averaged 0.0354 CPU and peaked at 0.1924 CPU; service memory peaked at 247,177,220 bytes. Database disk usage peaked at 3,700,723,700 bytes and ended at 3,169,370,000 bytes. This window includes backup/preflight activity. Metrics came from Render's [CPU](https://api-docs.render.com/reference/get-cpu), [memory](https://api-docs.render.com/reference/get-memory), and [disk](https://api-docs.render.com/reference/get-disk-usage) APIs. They are a baseline, not candidate production performance measurements.

The [error-log sample](live-error-sample.json) hit its 100-record limit. An expanded two-second window contained 92 `Phoenix.Router.NoRouteError` entries, consistent with requests probing nonexistent routes. The built candidate returned safe JSON 404s for JSON, wildcard, and HTML Accept headers without route-error stacks or request-process termination logs in the [local HTTP smoke](scanner-smoke-results.json). This explains the sampled burst, not every production error.

## Backup and migration rehearsal

A Render on-demand logical export created at **2026-09-04 22:36 UTC** was downloaded with explicit approval into a private local directory and restored successfully into isolated PostgreSQL 16 (Docker, two CPUs, 4 GB memory). The compressed export was 97,245,033 bytes. Only Ecto Repo and migrations ran against the restored production data: no application, OAuth refresh, Oban, or callback delivery processes started.

| Check | Result |
| --- | --- |
| Local PostgreSQL 16 regression suite | 68 tests, 0 failures |
| Restored action rows | 7,586,370 before; 7,582,357 after |
| Pending callbacks | **7,147 before and after** |
| Duplicate historical rows removed | 4,013; retained identity selection verified before/after |
| OAuth records with credential metadata scrubbed | 17 |
| Applied migrations | `20260904190000`, `20260904191000`, `20260904192000`, `20260904193000` |
| Migration duration | **94.860 seconds locally** |
| Unique callback index | Valid and unique |
| Active work / legacy jobs | Every active action has a durable queue; no runnable legacy worker jobs |
| Initial cooldown | Every seeded queue waits at least its full configured interval |
| Migration rerun | No-op |

The restored database grew from 1.718 GB to 2.095 GB, with 459 MB measured WAL. Two-second sampling observed up to 648 MB in default-tablespace temporary files. Cumulative temporary writes were 4.724 GB, including the rehearsal's pre-migration verification queries; this is **not** peak concurrent disk use. The restored database is much smaller than production because it has freshly rebuilt storage/indexes and omits the invalid index described below. Do not treat its absolute size, sampled peak, or 95-second timing as a production guarantee.

Propose increasing the Render database disk from **5 GB to at least 10 GB before cutover**, then recheck actual free space. This is a proposed production/billing change, not an action already taken. Reserve a **30-minute maintenance window** for paused replacement, migration, verification, and reopening; target a short interruption and stop at failed gates. Local migration timing alone does not predict Render deployment duration.

The approved cleanup is complete: downloaded backup, extracted dump, raw rehearsal logs, restored database, container, and its anonymous data volume were deleted. The Render export remains available. See [rehearsal results](restore-results.json), [space measurements](restore-space-results.json), [cleanup verification](restore-cleanup.json), and [guarded rehearsal script](../../scripts/rehearse_restore.exs).

## Schema reconciliation

Production's historical migration marker `20240901233756` is absent from repository history. Its original source remains unknown; no invented migration was added. Current schema metadata and the real export establish compatibility with the candidate:

- Extra nullable `action_executions.metered` and `portal_id` columns are preserved and ignored by the application.
- Existing production `queue_id`, `callback_id`, `processed`, and timestamp constraints are stricter than the original repository migration; candidate writes satisfy them. Legacy rate fields are text rather than varchar.
- Production's `on_hold_until` is timestamp with time zone; the candidate converts it to its UTC timestamp representation. The local UTC restore completed that conversion successfully; confirm production migration session timezone is UTC before executing it.
- All nine **valid** pre-existing action indexes survived the restore and migration. The new unique callback index brings the restored total to ten.
- `idx_action_executions_queue_id_gin_trgm` is **invalid and not ready** in production (`indisvalid=false`, `indisready=false`), occupying 67,633,152 bytes. It is absent from the export manifest. The candidate does not depend on it. Removing this unused index is a separate proposed cleanup; no live index was changed. Its storage must still be counted for cutover headroom.
- Extensions include `pg_trgm` and `pg_stat_statements`; no user-defined table triggers were found. The historical migration marker remains present after rehearsal.

## Current cooldown review

A later live snapshot, separate from the backup and preflight counts:

| Queue | Pending | Latest rate | Earliest deadline | Ideal drain after migration |
| --- | ---: | --- | --- | --- |
| `queue:44707895:1602619037:74663982:1` | 39 | 25/day | October 2, 12:31 UTC | Two daily windows; first delivery no earlier than one full day |
| `queue:6863484:1649334316:74663982:0` | 5,939 | 3/second | October 2, 22:03 UTC | About 33 minutes |
| `queue:6863484:605621787:74663982:0` | 15 | 5/second | October 2, 22:40 UTC | About 3 seconds |

These are lower-bound calculations assuming no new arrivals, retries, portal contention, or HTTP delay. The two fast queues share a portal. Re-query immediately before cutover. Preserve full cooldowns; no early rate-budget reset is proposed.

## Proposed Render configuration for the approved cutover

Prepare these changes together; do not apply them to the old running service during candidate preparation.

| Setting | Paused candidate | After migration and verification |
| --- | --- | --- |
| Build | `./build.sh` | same |
| Start | `_build/prod/rel/throttle/bin/throttle start` | same |
| Toolchain | Explicit `ELIXIR_VERSION=1.19.5`; pin `ERLANG_VERSION` to the exact OTP 28 release that passes Linux CI | same |
| `PORT` | Preserve `10000` | same |
| Admission / dispatch flags | Both `false` | Both `true` while ingress remains gated, then reopen |
| Health-check path | `/api/live` | `/api/health` |
| Config API | Leave `THROTTLE_CONFIG_API_KEY` unset (closed) until authorized clients are provisioned | closed unless separately provisioned |
| Database TLS | Preserve URL; verify CA and name from Render, set `DATABASE_TLS_SERVER_NAME` only if private alias needs the verified certificate hostname | same |
| Secrets | Preserve encryption key, HubSpot app credentials, session secret, redirect URI | same |
| Public ingress | Render default maintenance page, actual webhook path verified 503 | Reopen after readiness and due-time checks |
| Automatic deploy | Disabled | Disabled |

Use [ROLLOUT.md](ROLLOUT.md) for ordered steps and the paused forward-fix recovery procedure. After migration, restarting the old dispatcher is unsafe. Refresh the backup near the actual window; this rehearsal backup does not contain later accepted work.

## Remaining gates

1. Obtain approval to push this branch to the existing `05bmckay/Throttler` GitHub remote, run Linux CI, and require the final candidate SHA to pass. No push or remote CI has occurred. Review/merge and deployment remain separate actions.
2. Establish authorized Render runtime access. Verify the live buffer counters can be inspected without dumping payloads, and verify database TLS from the actual Render runtime. Confirm production migration timezone is UTC.
3. Approve/provision disk headroom and the maintenance window. Verify a recent backup is available before cutover.
4. Complete the paused deployment/migration checks, disposable HubSpot smoke, and first-hour observation only as part of an approved rollout. Observe daily-rate behavior through its next due interval before declaring sustained production acceptance.
