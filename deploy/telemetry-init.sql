-- Kiosk hosted live demos — shared live-activity telemetry store
--
-- ONE shared database, ONE append-only table, that ALL demos write to (each app
-- sets KIOSK_TELEMETRY_DB_URL to this DB). The landing tile reads the ALL-apps
-- aggregate; each demo page reads its own scope. App-layer, opt-in
-- (KIOSK_TELEMETRY=1), privacy-safe — see kiosk-demo-*/app/services/demo_telemetry.rb.
--
-- Privacy: agent_hash is a PER-APP salted hash used for distinct-counts only —
-- NOT joinable across apps (no cross-provider tracking), never a raw agent id,
-- never PII. Rows are counts of generic action_kinds; no per-assistant detail.
--
-- HOW TO RUN (as the cluster superuser, once at provisioning):
--   psql -v ON_ERROR_STOP=1 -v tm_pw=… -f telemetry-init.sql
-- (tm_pw is the RAW password, unquoted — the script escapes it via :'tm_pw'.)
--
-- Then set each app's env:
--   KIOSK_TELEMETRY=1
--   KIOSK_TELEMETRY_DB_URL=postgres://kiosk_telemetry:<pw>@127.0.0.1/kiosk_demo_telemetry
--   KIOSK_TELEMETRY_SALT=<a distinct random salt PER APP>   # keeps hashes non-joinable
--
-- The demos also create this table idempotently at runtime (ensure_schema!), so
-- this file is the canonical/authoritative provisioning for the shared DB and a
-- documented schema; a fresh app boot against an empty shared DB self-heals.

\set ON_ERROR_STOP on

-- ── Least-privilege LOGIN role for telemetry writes/reads ───────────────────
-- Idempotent create in the OUTER SQL so \gexec can interpolate the password
-- variable. (A :var is NOT substituted inside a DO/dollar-quoted block, so the
-- literal ":tm_pw" would reach the server and error "syntax error at :".)
-- :'tm_pw' single-quotes and escapes the password safely.
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', 'kiosk_telemetry', :'tm_pw')
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'kiosk_telemetry')\gexec

-- ── The shared DB (guarded create; \gexec runs the CREATE only if absent) ───
SELECT 'CREATE DATABASE kiosk_demo_telemetry OWNER kiosk_telemetry'
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'kiosk_demo_telemetry')
\gexec

\connect kiosk_demo_telemetry

-- ── The single append-only events table ─────────────────────────────────────
CREATE TABLE IF NOT EXISTS demo_telemetry_events (
  id          bigserial   PRIMARY KEY,
  app         text        NOT NULL,   -- provider/demo slug (scopes the aggregate)
  action_kind text        NOT NULL,   -- generic: registered/browsed/ordered/booked/…
  agent_hash  text        NOT NULL,   -- per-app SALTED hash; distinct-count ONLY
  at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_demo_telemetry_events_at     ON demo_telemetry_events (at);
CREATE INDEX IF NOT EXISTS idx_demo_telemetry_events_app_at ON demo_telemetry_events (app, at);

GRANT CONNECT ON DATABASE kiosk_demo_telemetry TO kiosk_telemetry;
GRANT SELECT, INSERT ON demo_telemetry_events TO kiosk_telemetry;
GRANT USAGE, SELECT ON SEQUENCE demo_telemetry_events_id_seq TO kiosk_telemetry;

-- Housekeeping (optional) is MANUAL — nothing trims this table on a schedule,
-- and nothing in deploy/ runs on a schedule at all (K-630). The
-- aggregates only look back 10 min / 1 h / all-time-registered, so rows past the
-- registered-count horizon can be DELETEd to reclaim disk. Note the app role
-- above holds SELECT+INSERT only, so that DELETE is a DB-owner/superuser job.
