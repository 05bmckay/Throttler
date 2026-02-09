# PROJECT KNOWLEDGE BASE

**Generated:** 2026-02-09
**Commit:** 86fd38b
**Branch:** main

## OVERVIEW

HubSpot workflow action throttling system. Receives webhook callbacks, batches them into Postgres, then processes via rate-limited Oban workers that call back to HubSpot. Phoenix 1.6 + Ecto + Oban 2.10 + PostgreSQL.

## STRUCTURE

```
.
├── lib/
│   ├── throttle/            # Core domain: GenServers, workers, schemas, encryption
│   ├── throttle_web/        # API-only Phoenix layer (no LiveView/channels)
│   └── throttle.ex          # Thin context — delegates to GenServers
├── config/                  # Environment configs (dev, prod, release)
├── priv/repo/migrations/    # Ecto migrations (5 total)
├── test/                    # Tests (broken — missing support modules)
├── assets/                  # Frontend assets (React Scripts, mostly unused)
├── throttler-ratelimiter/   # Standalone JS rate-limiter tool (separate concern)
└── build.sh                 # Production release build script
```

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| Incoming webhook handling | `lib/throttle_web/controllers/hubspot_controller.ex` | Entry point for HubSpot actions |
| Throttle config CRUD | `lib/throttle_web/controllers/throttle_config_controller.ex` | Upsert via composite unique on `(portal_id, action_id)` |
| OAuth flow | `lib/throttle_web/controllers/oauth_controller.ex` + `lib/throttle/oauth_manager.ex` | Tokens encrypted at rest |
| Action batching (DB writes) | `lib/throttle/action_batcher.ex` | GenServer, adaptive flush interval, batches into `action_executions` |
| Rate-limited execution | `lib/throttle/throtter_worker.ex` | **390-line Oban worker** — HTTP calls, retry, snooze, batch processing |
| Job recovery | `lib/throttle/workers/job_cleaner.ex` | Cron every 5min, finds orphaned queues, re-schedules Oban jobs |
| Config caching | `lib/throttle/config_cache.ex` | GenServer, **no TTL** — caches indefinitely |
| Per-portal HTTP batching | `lib/throttle/portal_queue.ex` | DynamicSupervisor + Registry per portal |
| Queue ID generation | `lib/throttle/queue_manager.ex` | Format: `queue:{portal}:{workflow}:{action}:{index}` |
| Encryption | `lib/throttle/encryption.ex` | AES-256-GCM via `ENCRYPTION_KEY` env var |
| DB schemas | `lib/throttle/schemas/` | `ActionExecution`, `ThrottleConfig`, `SecureOAuthToken` |
| Routes | `lib/throttle_web/router.ex` | API-only: `/api/hubspot/action`, `/api/config`, `/api/oauth/*` |

## EXECUTION FLOW

```
HubSpot webhook POST /api/hubspot/action
  → HubSpotController (signature verify → 204 immediate)
  → Throttle.create_action_execution/1
  → ActionBatcher.add_action/1 (cast, buffered)
  → flush_buffer → Repo.insert_all(ActionExecution)
  → ensure_job_exists → Oban.insert(ThrottleWorker)
  → ThrottleWorker.perform/1 (rate-limited batch processing)
  → OAuthManager.get_token → HTTP callback to HubSpot
  → mark_actions_processed
```

## SUPERVISION TREE

```
Throttle.Supervisor (one_for_one)
├── Throttle.Repo
├── ThrottleWeb.Telemetry
├── Phoenix.PubSub
├── ThrottleWeb.Endpoint
├── Throttle.ActionBatcher          # Batches DB inserts
├── Throttle.ConfigCache            # In-memory config (no TTL!)
├── Throttle.JobBatcher             # Batches Oban inserts (POSSIBLY UNUSED)
├── Oban                            # queues: default=10, rate_limited=1, maintenance=1
├── Throttle.PortalRegistry         # Registry for per-portal queues
└── Throttle.PortalQueueSupervisor  # DynamicSupervisor for PortalQueue GenServers
```

## CONVENTIONS

- API-only Phoenix — no HTML views, no LiveView, no channels
- GenServer-heavy architecture: 4 GenServers + DynamicSupervisor
- Oban for all background work; `unique` constraint on `(worker, args.queue_id)`
- OAuth tokens encrypted with AES-256-GCM before storage
- Queue IDs encode full context: `queue:{portal}:{workflow}:{action}:{index}`
- Adaptive batch flush: interval adjusts between 500ms–5s based on throughput

## ANTI-PATTERNS (THIS PROJECT)

- **Filename typo**: `throtter_worker.ex` should be `throttle_worker.ex` (module is `Throttle.ThrottleWorker`)
- **JobBatcher appears unused** — started in supervision tree but no callers found
- **ConfigCache has no TTL or invalidation** — stale configs persist until restart
- **ThrottleWorker is 390 lines** — mixes HTTP client, retry logic, batch processing
- **Tests are broken** — missing `config/test.exs`, missing `test/support/` dir with `DataCase`/`ConnCase`
- **Logger.warn** used in config_cache.ex — deprecated, use `Logger.warning`
- **ActionExecution changeset** missing fields: `last_failure_reason`, `consecutive_failures`, `on_hold_until`
- **Hardcoded secrets** in `config/dev.exs` and `config/prod.exs` (secret_key_base)
- **SSL verify disabled** (`verify: :verify_none`) in DB connections
- **LiveView signing salt** is placeholder `"CHANGE_ME"`

## COMMANDS

```bash
# Dev
mix deps.get
mix ecto.setup              # create + migrate + seed
mix phx.server              # start dev server (port 4000)

# Build (production release)
./build.sh                  # deps → compile → assets → digest → release

# Test (currently broken)
mix test                    # needs config/test.exs + test/support/

# DB
mix ecto.migrate
mix ecto.reset              # drop + setup
```

## NOTES

- Oban cron runs `JobCleaner` every 5min — safety net for orphaned queues
- `ThrottleWorker` uses custom `backoff/1` to correct attempt count after snoozes
- `ActionBatcher` uses `on_conflict: :nothing` for insert deduplication
- `PortalQueue` calls `ThrottleWorker.process_with_token/2` directly — tight coupling
- No CI/CD pipeline configured (no GitHub Actions, no Dockerfile)
- `throttler-ratelimiter/` is a standalone JS project in the repo root (separate concern)
