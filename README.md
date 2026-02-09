# Throttle

Rate-limited HubSpot workflow action processor. Receives webhook callbacks from HubSpot, buffers them into PostgreSQL, and processes them back to HubSpot at configurable throughput limits per workflow action.

## Why This Exists

HubSpot workflow custom actions fire webhooks for every enrollment. High-volume workflows can generate thousands of callbacks per minute, but the HubSpot API enforces rate limits on completion callbacks. Throttle sits between the webhook and the callback — accepting actions instantly (204), batching writes to Postgres, then draining them back to HubSpot at whatever rate each portal/action is configured for.

## How It Works

```
HubSpot webhook                                          HubSpot API
     │                                                        ▲
     ▼                                                        │
POST /api/hubspot/action                          POST /automation/v4/actions/
     │  (signature verified)                       callbacks/complete
     ▼                                                        │
ActionBatcher (GenServer)                         HubSpotClient (Finch)
     │  buffer → flush every 500ms-5s                         ▲
     ▼                                                        │
Repo.insert_all(action_executions)                PortalQueue (per-portal GenServer)
     │                                                        ▲
     ▼                                                        │
Oban.insert(ThrottleWorker)  ──►  ThrottleWorker.perform/1 ──┘
     (unique per queue_id)         fetch batch → dispatch to portal queues
```

Each portal+workflow+action combination gets a unique queue ID (`queue:{portal}:{workflow}:{action}:{index}`). The worker processes one batch per rate-limit interval, then either snoozes (short intervals) or schedules a new job (long intervals).

## Quick Start

```bash
# Install dependencies
mix deps.get

# Create and migrate the database
mix ecto.setup

# Start the server (port 4000)
mix phx.server
```

### Required Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `DATABASE_URL` | Yes | PostgreSQL connection string |
| `SECRET_KEY_BASE` | Production | Phoenix signing key (generate with `mix phx.gen.secret`) |
| `ENCRYPTION_KEY` | Yes | AES-256-GCM key for OAuth token encryption at rest |
| `HUBSPOT_CLIENT_ID` | Yes | HubSpot app OAuth client ID |
| `HUBSPOT_CLIENT_SECRET` | Yes | HubSpot app OAuth client secret |
| `HUBSPOT_REDIRECT_URI` | Production | OAuth callback URL (e.g. `https://yourapp.com/api/oauth/callback`) |
| `BASE_URL` | Production | Public hostname for the app |
| `PORT` | No | HTTP port (default: 4000) |

## API

### Webhook Endpoint

```
POST /api/hubspot/action
```

Receives HubSpot workflow action callbacks. Signature-verified via HMAC-SHA256 (v2). Returns `204` immediately — processing happens asynchronously.

### Throttle Configuration

```
POST /api/config
```

Create or update a throttle config for a portal/action pair:

```json
{
  "portal_id": 12345,
  "action_id": 67890,
  "max_throughput": "10",
  "time_period": "1",
  "time_unit": "seconds"
}
```

```
GET /api/config/:portal_id/:action_id
```

Retrieve the current config.

### OAuth

```
GET /api/oauth/authorize    # Redirects to HubSpot OAuth consent
GET /api/oauth/callback     # Handles the OAuth code exchange
```

## Architecture

### Supervision Tree

```
Throttle.Supervisor (one_for_one)
├── Throttle.Repo                    Ecto/PostgreSQL
├── ThrottleWeb.Telemetry            Metrics
├── Phoenix.PubSub                   PubSub
├── ThrottleWeb.Endpoint             HTTP server
├── Throttle.FlushTaskSupervisor     Task.Supervisor for async DB flushes
├── Throttle.ActionBatcher           Buffers incoming actions, flushes to DB
├── Throttle.ConfigCache             In-memory config with 5-min TTL
├── Throttle.OAuthRefreshLock        Per-portal mutex for token refreshes
├── Finch (Throttle.Finch)           HTTP connection pool (25 conns × 2 pools)
├── Oban                             Background job processing
├── Throttle.PortalRegistry          Registry for per-portal queue processes
└── Throttle.PortalQueueSupervisor   DynamicSupervisor (max 500 children)
    └── Throttle.PortalQueue         One GenServer per active portal
```

### Key Modules

| Module | Role |
|--------|------|
| `ActionBatcher` | GenServer that buffers webhook payloads and batch-inserts them into `action_executions`. Adaptive flush interval (500ms–5s). Async flushes via Task.Supervisor. Flushes synchronously on shutdown to prevent data loss. |
| `ThrottleWorker` | Oban worker. Fetches unprocessed actions for a queue, dispatches to per-portal queues, handles snooze/reschedule logic. |
| `HubSpotClient` | Finch-based HTTP client for the HubSpot callbacks API. Handles 429 rate limits, 403 blocks, retries. |
| `ActionQueries` | Ecto queries for batch fetching, marking processed, tracking consecutive failures with hold-off. |
| `PortalQueue` | Per-portal GenServer that batches HTTP calls (900ms flush, max 100). Fetches OAuth tokens and delegates to `HubSpotClient`. |
| `ConfigCache` | GenServer cache with 5-minute TTL and `bust_cache/2` invalidation API. |
| `OAuthManager` | Token storage, encryption (AES-256-GCM), refresh logic. |
| `OAuthRefreshLock` | GenServer mutex — serializes token refreshes per portal to prevent race conditions. |
| `JobCleaner` | Oban cron (every 5 min) — finds queues with unprocessed actions but no active job, re-schedules them. |
| `DataRetentionWorker` | Oban cron (daily 3AM UTC) — prunes processed actions older than 30 days in batches of 1000. |

### Database Schema

**`action_executions`** — Webhook payload buffer. Each row is one HubSpot callback waiting to be processed.

| Column | Type | Notes |
|--------|------|-------|
| `queue_id` | string | `queue:{portal}:{workflow}:{action}:{index}` |
| `callback_id` | string | HubSpot callback identifier |
| `processed` | boolean | `false` until successfully called back |
| `max_throughput` | string | Rate limit (from config at time of receipt) |
| `time` / `period` | string | Rate window (e.g. "1" / "seconds") |
| `consecutive_failures` | integer | Incremented on HTTP errors, triggers hold-off at 3 |
| `on_hold_until` | datetime | Set to now + 30min after 3 consecutive failures |

Indexed: `(queue_id, processed) WHERE processed = false`

**`throttle_configs`** — Per-action rate limit settings. Unique on `(portal_id, action_id)`.

**`oauth_tokens`** — Encrypted HubSpot OAuth credentials. Unique on `portal_id`. Tokens encrypted with AES-256-GCM at rest.

## Production Build

```bash
./build.sh
# or manually:
mix deps.get --only prod
MIX_ENV=prod mix compile
MIX_ENV=prod mix release --overwrite
```

The release reads all secrets from environment variables at boot via `config/runtime.exs`.
