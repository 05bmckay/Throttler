# Throttler audit — September 4, 2026

Historical baseline at commit `1838519`. Source references and findings below describe that revision. See [candidate results](../../readiness/RESULTS.md) for the subsequent implementation and validation.

The best opportunity is to simplify ownership of work: persist admission before acknowledging it, keep queue timing in Postgres, and give callback delivery one owner. Current production has substantial CPU headroom. A larger instance or a wholesale language/framework rewrite is not supported by the measurements.

Scope: current application source, migrations, tests, Render configuration/deployments, 24-hour metrics and logs, and read-only production database aggregates. Local HEAD and the live deployment both use `1838519b61ac8ce5f540e2632513486b9890f4df` (Render deployment `dep-dac80pm10ojc73ehaos0`). No application implementation, production data, configuration, or deployment was changed. Audit artifacts and isolated local characterization tests were added.

## Production evidence

Metrics cover approximately September 3, 20:12 UTC through September 4, 20:12 UTC, at five-minute resolution. These are sampled values, not instantaneous peaks or a load test.

| Measurement | Observed result |
| --- | --- |
| App CPU / allocated CPU | Mean 2.04%; highest sample 41.29% of one core |
| App memory | Mean 209 MiB; highest sample 235 MiB; allocation 2 GiB |
| Database CPU | Mean 1.37%; highest sample 9.92% of one core |
| Render HTTP responses | 353,203 HTTP 200; 7 HTTP 304; 1 HTTP 400; 43 HTTP 404; no nonzero 5xx series |
| Largest HTTP 200 bucket | 53,176 responses in a five-minute bucket |
| Current pending work | 42 actions across two daily-rate queues; no expired active actions, permanent failures, or active duplicate callback groups |
| Database connections | 29; no blocked sessions or transactions older than one minute |
| Database storage | 3.01 GB database; action table plus indexes 3.00 GB |
| Action table estimates | 7.57 million live tuples; 0.97 million dead tuples; estimates are not exact counts |
| Action indexes | 10 indexes totaling 1.63 GB, exceeding the 1.37 GB heap |
| Retention | 70,250 terminal records eligible for the existing daily retention job at inspection time |
| Quiet 15-minute delivery sample | 64 outbound batches / 86 actions; 45 batches contained one action |
| Same sample, webhook acknowledgment | 87 responses; median 0.617 ms, p95 0.9 ms, max 10 ms — application logging only, before persistence |

The two pending queues contained 39 actions at 25/day and 3 actions at 5/day. Pending work is expected at these configured rates; this snapshot is not evidence of a stuck queue. The observation that work drains normally does not establish that configured spacing survives restarts.

The 24-hour warning scan returned six entries: four HubSpot rate-limit messages, one socket-closed retry, and one associated rate-limit scheduling message. Error-level scanning returned 44 process-termination headers and one socket-closed error. A targeted context inspection identified a scanner request to `/sitemap.xml` returning 404; a separate scan found 43 NoRouteError entries. One remaining termination was not classified. These are not 44 proven background-worker crashes.

Render's HTTP latency API rejected the query because the workspace is on Hobby. CPU/memory/request counts were available. No account upgrade was performed. Database memory includes cache and reached roughly 3.77 GiB out of 4 GiB; this alone does not demonstrate memory pressure.

The old unfiltered callback update accumulated a 753 ms mean in `pg_stat_statements`; the current update with `NOT processed` accumulated a 0.432 ms mean. Those counters span back to April 7 and are not a controlled before/after benchmark. More usefully, a short live delta measured six updated rows across four current callback-update calls in 0.730 ms total. The corresponding claim-query delta was 98 calls, six returned rows, and 3.68 ms total. A read-only representative pending-row SELECT used an index and completed in 0.086 ms. No write query was run with EXPLAIN ANALYZE.

## Prioritized findings

### 1. [P1] Successful webhook admission is still non-durable

**Source:** `lib/throttle/action_batcher.ex:69–95`, `lib/throttle_web/controllers/hubspot_controller.ex:11–27`.

The batcher replies `:ok` after placing an action in memory; the controller then returns HTTP 200/BLOCK. Database insertion happens later, ordinarily behind a 0.5–5 second timer and potentially longer under backlog/failure. An abrupt process/instance loss can permanently lose acknowledged callbacks. `terminate/2` helps graceful shutdown but cannot guarantee persistence after SIGKILL, VM loss, or database failure. The local admission probe confirms success with no database row.

**Recommendation:** acknowledge only after a durable idempotent insert. Benchmark direct insertion first; if peak traffic requires batching, retain a bounded microbatch whose callers are released only after commit. Do not preserve early acknowledgment merely to keep sub-millisecond response metrics. HubSpot documents that blocked actions eventually expire and allow the workflow to continue, so losing the callback is consequential.

### 2. [P1] Database deduplication does not exist

**Source:** `lib/throttle/action_batcher.ex:236–247`, `lib/throttle/action_queries.ex:65–95`; production index inventory.

`on_conflict: :nothing` has no callback uniqueness constraint to conflict with: only the generated row primary key is unique. Two copies of the same callback can be inserted and leased separately. Deduplicating a single HTTP batch and marking existing duplicate rows processed does not cover concurrent batches or a retry arriving after completion. Both cases are reproduced locally. Current production had no active duplicate groups; this is a demonstrated vulnerability, not a claim of ongoing duplicate delivery.

**Recommendation:** persist a unique callback identity, scoped to the verified HubSpot identity contract, before creating work. Retain deduplication history for the applicable retry/replay window. When adding the constraint, also fix the batcher's `Enum.drop(actions, inserted_count)`: conflicts must consume attempted inputs, not leave them permanently queued or remove the wrong entries. Clean existing duplicates before building the constraint.

### 3. [P1] Rate limits reset after restart and multiply across instances

**Source:** `lib/throttle/queue_runner.ex:41–60, 69–94`, `lib/throttle/action_queries.ex:65–95`.

Every new runner schedules an immediate tick; last dispatch/next eligible time exists only in process timers. A queue that sent 25/day shortly before a deployment may send another 25 immediately when its runner starts. During rolling overlap, each instance has its own registry and can claim different rows under the full configured allowance. `SKIP LOCKED` protects row ownership during the claim transaction, not the queue's rate budget. Local probes confirm immediate startup for a daily rate and independent claims.

**Recommendation:** atomically reserve a queue's rate budget and next eligible time in a small durable queue-state row. Retain row claims for delivery, but coordinate scheduling across deployments/instances. Preserve the intended batch-versus-even-spacing semantics explicitly. Production currently has one configured instance; rolling overlap and restarts still matter.

### 4. [P1] OAuth encryption leaves a plaintext metadata copy

**Source:** `lib/throttle/oauth_manager.ex:20–29, 151–160`, `lib/throttle/schemas/secure_oauth_token.ex:17–29, 51–55`.

`store_token/1` merges the original token response into `token_response`. The changeset encrypts the two dedicated token fields but stores the metadata map unchanged. The local probe uses fake credentials and confirms the plaintext copy. A production aggregate found `access_token` and `refresh_token` metadata keys in 17 of 34 records; no token values were selected or displayed. No records had been created after the September 2 encryption fix, so those live records do not measure the new-install path after that deploy.

**Recommendation:** allowlist non-secret metadata on both initial storage and refresh, then remove credential keys from existing metadata in a controlled migration. Audit historical exposure before deciding credential rotation scope. Separate actual exposure from the fact that this field bypasses application encryption.

### 5. [P1] Lease eligibility does not fence out stale owners

**Source:** `lib/throttle/action_queries.ex:26–62`, `lib/throttle/portal_queue.ex:202–216`.

Claims have a deadline but no owner/generation token. Before sending, `processable_action_ids/1` checks terminal state and expiration, not whether this process still owns the lease. If delivery is delayed beyond lease expiry and another runner reclaims the row, the original in-memory item remains eligible too. Renewal by row ID also cannot distinguish owners. The local probe expires/reclaims a lease and confirms that the old claim still passes the dispatch check.

**Recommendation:** issue a claim token/version and require it for renewal, failure updates, and dispatch eligibility. Bound the send lifecycle to a valid claim. This still cannot guarantee exactly-once remote effects if HubSpot accepts a callback and the response/DB acknowledgment is lost; verify HubSpot's repeated-completion behavior and design for that uncertainty.

### 6. [P2] Delivery blocks the portal process; retry state exists in several places

**Source:** `lib/throttle/portal_queue.ex:44–51, 202–318`, `lib/throttle/hubspot_client.ex:17–42`.

The portal GenServer executes HTTP and `Process.sleep(2000)` retries synchronously. During that time it cannot consume enqueue messages, apply its in-state capacity check, or renew queued leases. The configured 10,000-item queue cap does not bound the mailbox. Separately, idle portal processes never exit, while the supervisor has a 500-child cap; reaching 500 distinct portals over a service lifetime can block the next portal even when earlier ones are idle.

**Recommendation:** keep one portal coordinator responsive, with bounded supervised delivery tasks and explicit admission. Consolidate retry scheduling into one persistent policy and stop idle coordinators. Retry transient transport/5xx errors; handle permanent failures without four identical immediate attempts. Keep per-portal Retry-After coordination.

### 7. [P2] JSON config writes crash, and the config API is a parallel configuration system

**Source:** `lib/throttle.ex:25–37`, `lib/throttle_web/router.ex:30–35`, `lib/throttle/action_queries.ex:99–123`.

The HTTP controller passes string-keyed JSON parameters, but upsert reads `attrs.max_throughput`, `attrs.time_period`, and `attrs.time_unit`, raising `KeyError` before the insert. Reproduced locally. These routes have no authentication, and the delivery path uses rates from action rows instead of the config table. The cache therefore is not a hot-path optimization. Deriving configuration from the newest *pending* action can also revert to an older rate when a newer configuration's row is completed first.

**Recommendation:** establish whether external clients use the config API. Remove it and its cache if obsolete; otherwise authenticate it, normalize validated parameters, and make it the single durable source of queue configuration. Do not repair the write error while leaving a public mutation endpoint unexamined.

### 8. [P2] Refresh timeout releases the mutex while the task keeps running

**Source:** `lib/throttle/oauth_refresh_lock.ex:104–135`.

The timeout handler demonitoring the task and removing its entry does not stop the task. Another refresh can start while the timed-out one still runs and may later write credentials. The task can make multiple network/database calls, exceeding the lock's 30-second timeout.

**Recommendation:** track the task PID and lifecycle, reconcile cancellation/late completion, and compare token versions before persisting refresh results. Coordinate refresh ownership across instances if scaling. Static finding; no real token refresh was triggered by this audit.

## Less work per callback

1. Remove the redundant `mark_actions_in_flight` UPDATE after the claim already set that value. Make any needed pre-send lease validation/renewal an owner-checked operation instead. Normal delivery currently performs a claim SELECT+UPDATE, eligibility SELECT, token SELECT/decryption, another in-flight UPDATE, and completion UPDATE, plus transaction boundaries.
2. Reduce successful-path logs. The quiet sample logged eight routine messages per batch through token retrieval and delivery, plus insert/request/lifecycle messages. Prefer counters, duration histograms, and one structured completion record when needed. Retain actionable errors.
3. Evaluate a portal token cache with expiry and refresh invalidation after fixing credential storage/refresh ownership. One SELECT and decryption per mostly single-action batch is avoidable, but no CPU speedup estimate is justified yet.
4. Remove unused `JobBatcher` (149 lines), unused query helpers, stale configuration files, and API-only frontend dependencies after checking callers/build packaging. `ThrottleWorker`'s delivery function is active; move it before removing the obsolete Oban bootstrap wrapper. Do not count active callback handling as dead code.
5. Review index redundancy with workload deltas and plans. The 67.6 MB trigram queue-ID index has zero recorded scans; other overlapping indexes have real scans. Ten indexes amplify insert/update/delete work. Do not blindly drop indexes or add more based on stale project notes. Some production indexes and migration `20240901233756` are absent from this checkout: reconcile schema history before changes.
6. Configure Render to use `/api/health`; its current health-check path is empty. The existing endpoint checks Postgres but not admission/dispatcher readiness. Build currently creates a release while Render starts `mix phx.server`; choose one tested production startup path. Remove duplicate build work after verifying assets are unused.

Production security configuration also needs attention: the database allowlist permits `0.0.0.0/0`, and `config/runtime.exs` disables TLS certificate verification. Restrict database ingress to required clients and enable verified TLS after testing the connection path. This audit did not change access rules.

## Proposed smaller architecture and validation order

`Verified webhook → durable idempotent inbox → portal coordinator + durable queue schedule → bounded HubSpot delivery → terminal state`

Keep Phoenix, Postgres, Finch, and Oban for maintenance. Consolidate volatile scheduling/lease/retry bookkeeping instead of replacing working infrastructure or switching every callback back to an Oban job. Store queue configuration/next dispatch separately from historical actions. The current ActionBatcher, QueueRunner, PortalQueue, and ThrottleWorker span 1,118 lines; replacement size and performance savings must be measured, not promised.

First address metadata secrets, durable admission/idempotency, and persisted rate/claim ownership. Next simplify dispatch, remove duplicate queries/logging/dead code, and tune indexes. Validate bursts comparable to the observed ~53k requests/five-minute bucket, abrupt exits immediately after acknowledgment, rolling overlap, daily-rate restarts, callbacks delayed past a lease, 401/429/5xx responses, DB failures, and replay after completion. Measure durable admission p95, achieved configured throughput, queries and log bytes per completed action, mailbox depth, callback age, and expiry risk. Increasing allowed customer throughput is not the optimization target.

Validation performed: existing suite **40 passed**; separate audit probes **7 passed**, confirming the undesirable behaviors described above. The probes are characterization evidence and intentionally are not acceptance tests for fixes. No live callbacks, load tests, or failure injection were performed. Existing Gettext/Phoenix deprecation warnings remain. Unrelated untracked files were preserved.

## Evidence and references

- [Audit reproduction probes](./audit_probe_test.exs)
- [Sanitized production summaries](./production-summary.json)
- [Render service metrics](https://render.com/docs/service-metrics)
- [Render CPU metrics API](https://api-docs.render.com/reference/get-cpu)
- [Render HTTP latency API](https://api-docs.render.com/reference/get-http-latency)
- [HubSpot custom-action blocking/expiration contract](https://developers.hubspot.com/docs/api-reference/latest/automation/workflow-actions/custom-action-reference)
