# Performance & Reliability Burndown

**Created:** 2026-02-09
**Branch:** main

## Status Key
- [ ] Pending
- [x] Complete

---

## P0 — Data Loss / Security Risk

- [x] **P0-1** ActionBatcher crash = data loss → Added terminate/2 + trap_exit (`eca4fb6`)
- [x] **P0-4** No HTTP timeouts → Added 15s recv / 10s connect + Oban timeout/1 60s (`9f39710`)
- [x] **P0-5** Non-transactional insert + job create → Wrapped in Repo.transaction (`eca4fb6`)

## P1 — Performance Bottleneck

- [x] **P1-1** O(n²) length/1 on every cast → Integer counter in state (`eca4fb6`)
- [x] **P1-3** :timer.sleep blocks workers → Propagate rate_limited error for Oban snooze (`9f39710`)
- [x] **P1-4** Missing composite index → Partial index on (queue_id, processed) WHERE false (`a19898b`)
- [x] **P1-7** 100 DB queries/job from queue_active? → Check every 5th snooze only (`9f39710`)

## P2 — Reliability Risk

- [x] **P2-1** Unbounded 100 snooze attempts → Reduced to 20 max (`9f39710`)
- [x] **P2-2** DynamicSupervisor unlimited children → max_children: 500 (`035f9d7`)
- [x] **P2-3** ConfigCache no TTL → 5-minute TTL + bust_cache/2 API (`832a6ad`)
- [x] **P2-4** No Oban pruning → Already configured (Oban.Plugins.Pruner)
- [x] **P2-7** String.to_integer crash → Integer.parse with 400 response (`035f9d7`)
- [x] **P2-8** Missing unique index on oauth_tokens.portal_id → Added (`a19898b`)

## P3 — Code Quality / Maintenance

- [x] **P3-1** Dead JobBatcher in supervision tree → Removed (`035f9d7`)
- [x] **P3-3** Filename typo throtter_worker → throttle_worker (`33da16d`)
- [x] **P3-4** Logger.warn deprecated → Logger.warning (`832a6ad`)
- [ ] **P3-7** Hardcoded secrets in dev/prod config — Move to env vars

## Remaining (Future Sprints)

- [ ] **P0-2** Webhook signature verification (security)
- [ ] **P1-2** Async flush in ActionBatcher (Task.Supervisor)
- [ ] **P1-5** HTTP connection pooling (Finch migration)
- [ ] **P0-3** OAuth token refresh mutex (race condition)
- [ ] **P2-5** Data retention worker for action_executions
- [ ] **P2-6** Fix batch failure double-UPDATE logic
- [ ] **P3-2** ThrottleWorker decomposition (390 lines → modules)
- [ ] **P3-6** Custom telemetry events + Oban logger
