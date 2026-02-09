# lib/throttle/ — Core Domain

## OVERVIEW

GenServer-heavy business logic: action batching, config caching, rate-limited execution, OAuth, encryption.

## ARCHITECTURE

Four GenServers + one DynamicSupervisor orchestrate the pipeline:

```
ActionBatcher (cast) → Repo.insert_all → ensure_job_exists → Oban
                                                                ↓
ConfigCache (call) ← ThrottleWorker.perform/1 → OAuthManager → HubSpot HTTP
                                                                ↓
                                            PortalQueue (per-portal, dynamic)
```

## WHERE TO LOOK

| Task | File | Notes |
|------|------|-------|
| Buffer incoming actions | `action_batcher.ex` | Adaptive flush 500ms–5s, max batch 100 |
| Process rate-limited batches | `throtter_worker.ex` | **Filename typo.** 390 lines, needs decomposition |
| Recover orphaned queues | `workers/job_cleaner.ex` | Oban cron, compares unprocessed vs active jobs |
| Cache throttle configs | `config_cache.ex` | **No TTL** — cache-aside, indefinite |
| Per-portal HTTP batching | `portal_queue.ex` | Registry + DynamicSupervisor, 900ms flush |
| Queue ID format | `queue_manager.ex` | `queue:{portal}:{workflow}:{action}:{index}` |
| Token encrypt/decrypt | `encryption.ex` | AES-256-GCM, key from `ENCRYPTION_KEY` env |
| Token CRUD + refresh | `oauth_manager.ex` | Stores encrypted, refreshes on 401 |
| Batch Oban inserts | `job_batcher.ex` | **Appears unused** — no callers found |

## GENSERVER PATTERNS

- `ActionBatcher`: cast-only client, `Process.send_after` timer, adaptive interval
- `ConfigCache`: call-only client (sync cache-aside), no invalidation
- `PortalQueue`: cast client, `:timer.send_after`, per-portal via Registry
- `JobBatcher`: cast client with retry/backoff — **likely dead code**

All GenServers use `__MODULE__` naming except `PortalQueue` (via Registry tuple).

## SCHEMAS (`schemas/`)

| Schema | Table | Key Fields |
|--------|-------|------------|
| `ActionExecution` | `action_executions` | `queue_id`, `callback_id`, `processed`, `max_throughput`, `time`, `period` |
| `ThrottleConfig` | `throttle_configs` | `portal_id`, `action_id`, `max_throughput`, `time_period`, `time_unit` |
| `SecureOAuthToken` | `oauth_tokens` | `portal_id`, `access_token` (encrypted), `refresh_token` (encrypted), `expires_at` |

Unique constraints: `ThrottleConfig` on `(portal_id, action_id)`.

## GOTCHAS

- `throtter_worker.ex` filename ≠ `Throttle.ThrottleWorker` module name
- `ThrottleWorker.backoff/1` adjusts attempt count to compensate for snooze-inflated max_attempts
- `ActionBatcher.get_existing_job/1` queries Oban args via `fragment("?->>'queue_id'")` — fragile JSON path
- `PortalQueue.process_with_token/2` calls into `ThrottleWorker` directly — circular-ish coupling
- `ActionExecution` changeset doesn't include `last_failure_reason`, `consecutive_failures`, `on_hold_until`
