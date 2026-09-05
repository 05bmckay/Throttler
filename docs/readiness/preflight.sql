-- READ ONLY. Run on the intended database before scheduling cutover.
BEGIN READ ONLY;
SET LOCAL statement_timeout = '120s';
SELECT version FROM schema_migrations ORDER BY version;
SELECT indexname, indexdef FROM pg_indexes WHERE tablename IN
  ('action_executions','oauth_tokens','throttle_configs') ORDER BY tablename,indexname;
SELECT c.relname AS index_name, i.indisvalid, i.indisready,
       pg_relation_size(c.oid) AS index_bytes
FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid
WHERE i.indrelid='action_executions'::regclass ORDER BY c.relname;
SELECT pg_database_size(current_database()) AS database_bytes,
       pg_total_relation_size('action_executions') AS action_table_and_index_bytes;
SELECT count(*) AS total,
       count(*) FILTER (WHERE NOT processed AND NOT permanently_failed) AS pending,
       count(*) FILTER (WHERE NOT processed AND NOT permanently_failed AND expires_at <= now()) AS expired_pending,
       count(*) FILTER (WHERE callback_id IS NULL OR callback_id='') AS invalid_callback_ids
FROM action_executions;
SELECT queue_id, count(*) AS pending, min(expires_at) AS first_deadline,
       max(on_hold_until) AS latest_hold
FROM action_executions WHERE NOT processed AND NOT permanently_failed GROUP BY queue_id;
-- Use the same latest-row ordering as the migration when checking cooldowns.
WITH pending AS (
  SELECT queue_id, count(*) AS pending, min(expires_at) AS first_deadline
  FROM action_executions WHERE NOT processed AND NOT permanently_failed GROUP BY queue_id
)
SELECT p.*, a.max_throughput, a.time, a.period
FROM pending p CROSS JOIN LATERAL (
  SELECT max_throughput, time, period FROM action_executions
  WHERE queue_id=p.queue_id ORDER BY id DESC LIMIT 1
) a;
SELECT count(*) AS duplicate_callback_groups FROM (
  SELECT callback_id FROM action_executions GROUP BY callback_id HAVING count(*) > 1
) duplicates;
SELECT count(*) AS cross_queue_identity_conflicts FROM (
  SELECT callback_id FROM action_executions GROUP BY callback_id HAVING count(DISTINCT queue_id) > 1
) conflicts;
SELECT count(*) AS tokens_with_credential_metadata FROM oauth_tokens
WHERE token_response ?| ARRAY['access_token','refresh_token','token','client_secret'];
COMMIT;
