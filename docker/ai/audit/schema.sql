-- ============================================================================
-- AI gateway audit record (todos.md #40, docs/ai-governance.md).
--
-- WHY A SECOND STORE AT ALL: Langfuse traces expire after 14 days. That is the
-- right call for DEBUGGING (todos.md #25 found ClickHouse's own logs at 5.65 GiB
-- and Paul's ruling was "traces are only interesting for about a week") and the
-- WRONG call for TRACEABILITY. If a public surface says something harmful, a key
-- leaks, or someone asks "what did your system tell me in June", 14 days of
-- evidence is nothing.
--
-- The resolution is not a longer TTL — that just re-creates the 5.65 GiB problem
-- and re-inflates the nightly backup. It is TWO records with different shapes:
--   FAT + SHORT  = Langfuse traces, full prompt/response bodies, 14d (unchanged)
--   SLIM + LONG  = this table, no bodies at all, 13 months
--
-- NO PROMPT OR RESPONSE BODIES ARE STORED HERE — only SHA-256 hashes, computed
-- inside ClickHouse by the export so the text never leaves the database. That
-- keeps the audit record cheap, keeps it safe to retain for a year, and still
-- answers the question that matters: "was THIS exact text produced by THIS
-- system at THIS time" (compare the hash), plus who/when/what-model/how-much.
--
-- Separate DATABASE, not a table in `default`: Langfuse owns `default` and runs
-- its own migrations there. Anything of ours in that database is one upgrade away
-- from being dropped or clashing.
-- ============================================================================

CREATE DATABASE IF NOT EXISTS ai_governance;

CREATE TABLE IF NOT EXISTS ai_governance.gateway_calls
(
    ts              DateTime64(3)           COMMENT 'When the call happened',
    system          LowCardinality(String)  COMMENT 'LiteLLM key alias = the docs/ai-inventory.yml system name',
    model           LowCardinality(String)  COMMENT 'Model actually served',
    trace_id        String                  COMMENT 'Langfuse trace id — join key while the fat trace still exists',
    status          LowCardinality(String)  COMMENT 'Observation level: DEFAULT / ERROR / WARNING',
    latency_ms      UInt32,
    input_tokens    UInt32,
    output_tokens   UInt32,
    total_tokens    UInt32,
    input_sha256    FixedString(64)         COMMENT 'SHA-256 of the prompt. NOT the prompt.',
    output_sha256   FixedString(64)         COMMENT 'SHA-256 of the response. NOT the response.',
    exported_at     DateTime DEFAULT now()  COMMENT 'When this row was harvested from Langfuse'
)
ENGINE = ReplacingMergeTree(exported_at)
-- ORDER BY trace_id makes the export IDEMPOTENT: re-running over an overlapping
-- window replaces rather than duplicates. The overlap is deliberate (see the
-- export script) — a missed day is unrecoverable once the 14d TTL passes.
PARTITION BY toYYYYMM(ts)
ORDER BY (trace_id)
-- 13 months: longer than any "what happened last year" question needs, and a
-- whole number of monthly partitions so expiry is a cheap partition drop — the
-- pattern todos.md #25 established for scanner.
TTL toDateTime(ts) + INTERVAL 13 MONTH
SETTINGS index_granularity = 8192;

-- Convenience view for the common question: per-system activity by day.
CREATE VIEW IF NOT EXISTS ai_governance.daily_by_system AS
SELECT
    toDate(ts)            AS day,
    system,
    model,
    count()               AS calls,
    sum(total_tokens)     AS tokens,
    round(avg(latency_ms)) AS avg_latency_ms,
    countIf(status = 'ERROR') AS errors
FROM ai_governance.gateway_calls
GROUP BY day, system, model
ORDER BY day DESC, calls DESC;
