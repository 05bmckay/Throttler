# Implementation overview

The candidate retains the existing action table, enforces unique callback identity, adds small durable queue/portal scheduling tables, and runs one bounded dispatcher. Admission acknowledges after commit. Due times, rate budgets, retry times, and claim ownership live in Postgres.

Rate contract: reserve at most the configured number of already-pending actions per interval and drain the reservation in API-sized chunks. New arrivals cannot spend old allowance. Retries retain their reservation while obeying portal-wide cooldown and exclusive ownership. This preserves burst-style ceilings rather than changing to even spacing.

Cutover stops old dispatchers and gates ingress with retryable responses before migration. Existing queues receive one full initial interval because legacy data does not reliably record last dispatch times. The candidate can boot paused before migration, with both delivery and Oban maintenance disabled.

See [RESULTS.md](RESULTS.md) for completed checks, [SECURITY.md](SECURITY.md) for dependency applicability, and [ROLLOUT.md](ROLLOUT.md) for outstanding production gates and recovery.
