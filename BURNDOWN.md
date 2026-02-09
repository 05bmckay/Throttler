# Performance & Reliability Burndown

**Created:** 2026-02-09
**Branch:** main

## Status Key
- [ ] Pending
- [x] Complete
- [~] In Progress

---

## P0 — Data Loss / Security Risk

- [ ] **P0-1** ActionBatcher crash = data loss (no terminate/2, no trap_exit) — `action_batcher.ex` [S]
- [ ] **P0-4** No HTTP timeouts on any HTTPoison call — `throtter_worker.ex`, `oauth_manager.ex` [S]
- [ ] **P0-5** Non-transactional insert_all + ensure_job_exists — `action_batcher.ex` [S]

## P1 — Performance Bottleneck

- [ ] **P1-1** O(n²) length/1 check on every cast — `action_batcher.ex` [S]
- [ ] **P1-3** :timer.sleep blocks Oban worker slots — `throtter_worker.ex` [S]
- [ ] **P1-4** Missing composite index on (queue_id, processed) — migration [S]
- [ ] **P1-7** queue_active? DB query on every snooze (100/job) — `throtter_worker.ex` [S]

## P2 — Reliability Risk

- [ ] **P2-1** Unbounded snooze (100 attempts), no circuit breaker — `throtter_worker.ex` [S]
- [ ] **P2-2** DynamicSupervisor has no max_children — `application.ex` [S]
- [ ] **P2-3** ConfigCache never invalidates (no TTL) — `config_cache.ex` [S]
- [x] **P2-4** ~~No Oban job pruning~~ — Already configured (Oban.Plugins.Pruner in config.exs)
- [ ] **P2-7** String.to_integer crash on bad input — `throttle_config_controller.ex` [S]
- [ ] **P2-8** Missing unique index on oauth_tokens.portal_id — migration [S]

## P3 — Code Quality / Maintenance

- [ ] **P3-1** JobBatcher is dead code (in sup tree, zero callers) — `job_batcher.ex`, `application.ex` [S]
- [ ] **P3-3** Filename typo: throtter_worker → throttle_worker — `throtter_worker.ex` [S]
- [ ] **P3-4** Logger.warn deprecated → Logger.warning — `config_cache.ex` [S]
- [ ] **P3-7** Hardcoded secrets in dev/prod config — `config/dev.exs`, `config/prod.exs` [S]
