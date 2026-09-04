# Core domain

Follow the repository's AGENTS.md. The former ActionBatcher, QueueRunner, PortalQueue, ConfigCache, JobBatcher, StartupRecovery, ThrottleWorker, and OAuthRefreshLock implementations have been removed.

`Admission` owns durable acceptance. `DispatchStore` owns queue budgets, portal cooldowns and UUID claims, action retries, and terminal transitions. `Dispatcher` owns only bounded task slots. `Delivery` performs HTTP and asks the store to apply its result. Portal locking precedes queue/action locking; stale owners cannot clear replacement leases.

Persist all timing needed after restart. Database transactions and callback uniqueness handle concurrent admissions. Use database row locks for OAuth refresh; do not detach refresh tasks that can outlive ownership. Store credentials only in the encrypted token columns; metadata must be allowlisted. Keep errors free of request or token material.

Oban maintenance expires unfinished callbacks and removes old terminal rows. It does not start per-queue processes. Preserve the 35-day deduplication horizon and callback-expiration grace period when changing retention.
