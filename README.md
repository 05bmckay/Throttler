# Throttle: HubSpot Workflow Action Throttling System - Project Documentation

This document details the structure, execution flow, and database schema of the Throttle application, based on code analysis.

## 1. Project Structure Overview

The application follows a standard Elixir Phoenix project structure. Key directories and files include:

*   **`config/`**: Application configuration files.
    *   `config.exs`: Base configuration, including Oban setup (queues, plugins like `Cron`, `Pruner`), Logger, Endpoint settings. Imports environment-specific configs. Defines Oban queues (`default`, `maintenance`, etc.).
    *   `dev.exs`, `prod.exs`, `test.exs` etc.: Environment-specific overrides.
    *   `runtime.exs` (Expected): Used for runtime configuration, especially loading secrets (Database URL, HubSpot secrets, Encryption Key) from environment variables.
*   **`lib/`**: Core application code.
    *   `lib/throttle/`: Core business logic (non-web).
        *   `application.ex`: OTP Application definition, starts and supervises child processes (Repo, Endpoint, `ConfigCache`, `ActionBatcher`, `JobBatcher`, Oban, Registry, DynamicSupervisor).
        *   `repo.ex`: Ecto Repository definition (using PostgreSQL).
        *   `oauth_manager.ex`: Context for storing, retrieving, encrypting/decrypting, and refreshing HubSpot OAuth tokens. Interacts with `Schemas.SecureOAuthToken`.
        *   `configurations.ex`: Context for CRUD operations on throttling rules. Interacts with `Schemas.ThrottleConfig`.
        *   `config_cache.ex`: GenServer providing an in-memory cache for `ThrottleConfig` records to reduce database lookups.
        *   `action_batcher.ex`: GenServer that batches the insertion of `ActionExecution` records into the database and ensures an Oban job exists for the corresponding queue.
        *   `job_batcher.ex`: GenServer that batches the insertion of Oban job changesets using `Oban.insert_all/2`. Includes retry logic with exponential backoff for failed batch insertions.
        *   `throttling.ex` (or `lib/throttle.ex`): Context for handling incoming actions, fetching configurations (via `ConfigCache`), and passing action data to `ActionBatcher`.
        *   `hub_spot_signature.ex`: Module for verifying incoming HubSpot webhook signatures (v1 & v2).
        *   `schemas/`: Ecto schema definitions.
            *   `secure_oauth_token.ex`: Schema for the `oauth_tokens` table.
            *   `throttle_config.ex`: Schema for the `throttle_configs` table.
            *   `action_execution.ex`: Schema for the `action_executions` table, storing details of incoming actions before they are processed.
        *   `workers/`: Oban background job worker modules.
            *   `throttle_worker.ex` (or similar name): Oban worker that processes batches of actions for a specific queue ID based on configuration, likely fetched from the `action_executions` table.
            *   `job_cleaner.ex`: Oban worker running periodically (via `Oban.Plugins.Cron`) to scan for unprocessed `ActionExecution` records and ensure an active `Throttle.ThrottleWorker` job exists in Oban for each corresponding `queue_id`. Schedules missing jobs if necessary.
        *   `encryption.ex`: Module handling the actual encryption/decryption logic. Requires `ENCRYPTION_KEY`.
    *   `lib/throttle_web/`: Phoenix web interface layer.
        *   `controllers/`: Handles incoming HTTP requests.
            *   `oauth_controller.ex`: Handles HubSpot OAuth2 authorization flow.
            *   `action_controller.ex` (or similar): Handles incoming HubSpot workflow action webhooks (`/api/hubspot/action`). Verifies signature and passes data to the `Throttle` context.
            *   `config_controller.ex`: Handles API requests for managing throttle configurations. Uses the cached `Throttle.get_throttle_config/2`.
        *   `views/`: Handles presentation logic.
        *   `router.ex`: Defines HTTP routes.
        *   `endpoint.ex`: Defines the web server entry point and middleware pipeline.
        *   `telemetry.ex`: Handles application telemetry events.
*   **`priv/`**: Private application assets.
    *   `priv/repo/migrations/`: Ecto database migration files defining table structures and indexes (including a unique index on `oban_jobs` for `Throttle.ThrottleWorker` and `queue_id`).
*   **`test/`**: Application tests.
    *   `test/test_helper.exs`: Configures the test environment.
    *   `test/support/`: Test support files.

## 2. Execution Flow: HubSpot Workflow Action Trigger

This flow describes what happens when a custom action in a HubSpot workflow triggers a webhook call to this application:

1.  **HTTP Request:** HubSpot sends a `POST` request to `/api/hubspot/action`.
2.  **Endpoint Processing (`ThrottleWeb.Endpoint`):** Request enters the Phoenix endpoint.
3.  **Routing (`ThrottleWeb.Router`):** Dispatches to `ThrottleWeb.ActionController` (or similar).
4.  **Signature Verification (Plug):** Verifies the HubSpot signature using `Throttle.HubSpotSignature`. Halts with `401` if invalid.
5.  **Action Handling (`ActionController`):** If the signature is valid:
    *   Extracts `portal_id`, `action_id`, and payload data.
    *   Calls a function in the `Throttle` context (e.g., `Throttle.handle_incoming_action/3`).
6.  **Configuration Fetch & Action Data Batching (`Throttle` context):**
    *   Calls `Throttle.get_throttle_config/2` (which uses `Throttle.ConfigCache`) to fetch the `ThrottleConfig` record from the cache or database.
    *   If no config exists, potentially returns an error to the controller (`400 Bad Request`).
    *   If config exists, prepares action attributes (including `queue_id`, payload, and relevant config details like rate limits).
    *   Calls `Throttle.ActionBatcher.add_action/1` to asynchronously add the action attributes to the batcher's buffer.
7.  **Webhook Response (`ActionController`):** The controller immediately sends a `204 No Content` response back to HubSpot to acknowledge receipt.
8.  **Action Execution Batch Insertion (`Throttle.ActionBatcher` - Background):**
    *   Periodically or when its buffer is full, the `ActionBatcher` GenServer flushes its buffer.
    *   It uses `Repo.insert_all` to insert batches of `ActionExecution` records into the database.
    *   After successful insertion for a `queue_id`, it calls `ensure_job_exists/2`.
9.  **Oban Job Scheduling (`Throttle.ActionBatcher.ensure_job_exists/2` - Background):**
    *   Checks if an active (`scheduled`, `available`, `executing`) `Throttle.ThrottleWorker` job already exists for the `queue_id` in the `oban_jobs` table.
    *   If *no* active job exists, it creates a *new* `Throttle.ThrottleWorker` job changeset with args derived from the action (e.g., `queue_id`, `max_throughput`, etc.).
    *   It inserts this *single* job using `Oban.insert/1`. The unique index on `oban_jobs` helps prevent duplicates in case of race conditions. *Note: `JobBatcher` is NOT used here; it's for different job types if needed.*
10. **Background Job Execution (`Throttle.ThrottleWorker` via Oban):**
    *   At some point later, Oban dequeues the `Throttle.ThrottleWorker` job for a specific `queue_id`.
    *   Oban calls `Throttle.ThrottleWorker.perform/1`.
    *   The worker queries the `action_executions` table for unprocessed actions matching its `queue_id`.
    *   It processes these actions according to the throttling logic (rate limits, etc.). This likely involves fetching OAuth tokens via `Throttle.OAuthManager` and calling external APIs via a module like `Throttle.Throttling.ActionExecutor`.
    *   It marks processed actions as `processed: true` in the `action_executions` table.
    *   The job completes or retries based on Oban's standard mechanisms.

## 2b. Execution Flow: Job Cleaner (Periodic)

1.  **Scheduled Execution (Oban Cron):** The `Oban.Plugins.Cron` plugin triggers `Throttle.Workers.JobCleaner.perform/1` every 5 minutes.
2.  **Fetch Queue IDs:**
    *   The worker queries `action_executions` for distinct `queue_id`s where `processed == false`.
    *   The worker queries `oban_jobs` for distinct `queue_id`s associated with active (`available`, `scheduled`, `executing`) `Throttle.ThrottleWorker` jobs.
3.  **Identify Missing Jobs:** It calculates the difference to find `queue_id`s that have unprocessed actions but no active Oban job.
4.  **Fetch Sample Action:** For each missing `queue_id`, it fetches *one* corresponding unprocessed `ActionExecution` record to get the necessary arguments (`max_throughput`, `time`, `period`).
5.  **Schedule Missing Job:** It creates a `Throttle.ThrottleWorker` job changeset with the fetched arguments and inserts it using `Oban.insert(changeset, on_conflict: :nothing)`. The unique database index ensures that if a job was created concurrently, this insert does nothing.

## 3. Database Schema Overview

The application uses PostgreSQL, managed by Ecto. Key tables defined by migrations:

1.  **`oauth_tokens` Table** (Schema: `Throttle.Schemas.SecureOAuthToken`)
    *   **Purpose:** Stores HubSpot OAuth credentials securely.
    *   **Columns:** (As before - `id`, `portal_id`, `access_token`, `refresh_token`, `expires_at`, timestamps)
    *   **Encryption:** Tokens are encrypted.

2.  **`throttle_configs` Table** (Schema: `Throttle.Schemas.ThrottleConfig`)
    *   **Purpose:** Stores throttling rules.
    *   **Columns:** (`portal_id`, `action_id`, `max_throughput`, `time_period`, `time_unit`, timestamps)
    *   **Constraints:** Composite unique index on (`portal_id`, `action_id`).

3.  **`action_executions` Table** (Schema: `Throttle.Schemas.ActionExecution`)
    *   **Purpose:** Stores details of incoming actions received via webhook, acting as a buffer before processing.
    *   **Columns:** (Likely includes: `id`, `queue_id`, `callback_id` or `payload`, `processed` (boolean), `max_throughput`, `time`, `period`, timestamps)
    *   **Indexes:** Likely an index on `(queue_id, processed)` for efficient querying by workers.

4.  **`oban_jobs` Table** (Managed by Oban)
    *   **Purpose:** Stores background job details for Oban.
    *   **Indexes:** Includes standard Oban indexes plus a custom unique, partial index on `(worker, args->>'queue_id')` where `worker = 'Throttle.ThrottleWorker'` to prevent duplicate processor jobs for the same queue.
