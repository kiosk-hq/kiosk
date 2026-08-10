-- Kiosk hosted live demos — Postgres provisioning
--
-- ONE Postgres 17 cluster, one database + one least-privilege LOGIN role per
-- hosted app (DB-per-app). Each demo's config/database.yml (production block)
-- expects db  kiosk_<app>_production  owned by role  kiosk_<app>  and
-- authenticates as KIOSK_<APP>_DB_USER / KIOSK_<APP>_DB_PASSWORD.
--
-- HOW TO RUN (as the cluster superuser, e.g. postgres):
--   psql -v ON_ERROR_STOP=1 \
--        -v gg_pw=…  -v af_pw=…  -v ho_pw=…  -v sk_pw=… \
--        -v st_pw=…  -v pl_pw=…  -v td_pw=…  -v pv_pw=… \
--        -f postgres-init.sql
--
-- Pass each password as a PLAIN psql variable (the RAW password, NO surrounding
-- quotes: -v gg_pw=S3cret!  — the script quote-escapes it safely via :'var').
-- Use the SAME value in env/<app>.env (KIOSK_<APP>_DB_PASSWORD).
-- Never commit real passwords.
--
-- Idempotent-ish: roles/dbs are created with guards so re-running is safe.
-- Run once at provisioning; re-run only adds what is missing.

\set ON_ERROR_STOP on

-- ── Roles (LOGIN, no CREATEDB/SUPERUSER — least privilege) ──────────────────
-- Idempotent per-role create in the OUTER SQL so \gexec can interpolate the
-- password variable. (A CREATE ROLE inside a DO/dollar-quoted block can NOT use
-- a :var — psql does not substitute variables inside dollar-quoted strings, so
-- the literal ":gg_pw" would reach the server and error "syntax error at :".)
-- Each password is spliced with :'var' quote-substitution, which single-quotes
-- and escapes it safely; the WHERE NOT EXISTS guard skips roles that already
-- exist, so re-running is a no-op.

SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', 'kiosk_getgrocery', :'gg_pw')
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'kiosk_getgrocery')\gexec
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', 'kiosk_atablefor', :'af_pw')
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'kiosk_atablefor')\gexec
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', 'kiosk_hoteling', :'ho_pw')
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'kiosk_hoteling')\gexec
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', 'kiosk_skooti', :'sk_pw')
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'kiosk_skooti')\gexec
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', 'kiosk_stylish', :'st_pw')
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'kiosk_stylish')\gexec
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', 'kiosk_philslist', :'pl_pw')
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'kiosk_philslist')\gexec
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', 'kiosk_tudu', :'td_pw')
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'kiosk_tudu')\gexec
-- prove.my KYC broker (gem dir kiosk-demo-prove; deploy domain kyc.demo.kiosk.tech)
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', 'kiosk_prove', :'pv_pw')
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'kiosk_prove')\gexec

-- ── Databases (one per app, owned by its role) ──────────────────────────────
-- CREATE DATABASE cannot run inside a transaction/DO block, and \gexec lets us
-- guard on existence. Each db is owned by its matching least-privilege role.

SELECT 'CREATE DATABASE kiosk_getgrocery_production OWNER kiosk_getgrocery'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'kiosk_getgrocery_production')\gexec
SELECT 'CREATE DATABASE kiosk_atablefor_production OWNER kiosk_atablefor'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'kiosk_atablefor_production')\gexec
SELECT 'CREATE DATABASE kiosk_hoteling_production OWNER kiosk_hoteling'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'kiosk_hoteling_production')\gexec
SELECT 'CREATE DATABASE kiosk_skooti_production OWNER kiosk_skooti'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'kiosk_skooti_production')\gexec
SELECT 'CREATE DATABASE kiosk_stylish_production OWNER kiosk_stylish'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'kiosk_stylish_production')\gexec
SELECT 'CREATE DATABASE kiosk_philslist_production OWNER kiosk_philslist'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'kiosk_philslist_production')\gexec
SELECT 'CREATE DATABASE kiosk_tudu_production OWNER kiosk_tudu'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'kiosk_tudu_production')\gexec
SELECT 'CREATE DATABASE kiosk_prove_production OWNER kiosk_prove'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'kiosk_prove_production')\gexec

-- ── Ownership / privilege hardening ─────────────────────────────────────────
-- Each app role owns its own DB (set above) so `db:prepare` can create the
-- `kiosk` schema, tables and (opt-in) RLS policies. No app role is granted on
-- any other app's DB — cross-tenant isolation at the cluster boundary, on top
-- of the per-agent app-layer isolation. Revoke PUBLIC connect so
-- only the owning role reaches each DB.

REVOKE CONNECT ON DATABASE kiosk_getgrocery_production FROM PUBLIC;
REVOKE CONNECT ON DATABASE kiosk_atablefor_production FROM PUBLIC;
REVOKE CONNECT ON DATABASE kiosk_hoteling_production  FROM PUBLIC;
REVOKE CONNECT ON DATABASE kiosk_skooti_production    FROM PUBLIC;
REVOKE CONNECT ON DATABASE kiosk_stylish_production   FROM PUBLIC;
REVOKE CONNECT ON DATABASE kiosk_philslist_production FROM PUBLIC;
REVOKE CONNECT ON DATABASE kiosk_tudu_production      FROM PUBLIC;
REVOKE CONNECT ON DATABASE kiosk_prove_production     FROM PUBLIC;

GRANT CONNECT ON DATABASE kiosk_getgrocery_production TO kiosk_getgrocery;
GRANT CONNECT ON DATABASE kiosk_atablefor_production  TO kiosk_atablefor;
GRANT CONNECT ON DATABASE kiosk_hoteling_production   TO kiosk_hoteling;
GRANT CONNECT ON DATABASE kiosk_skooti_production     TO kiosk_skooti;
GRANT CONNECT ON DATABASE kiosk_stylish_production    TO kiosk_stylish;
GRANT CONNECT ON DATABASE kiosk_philslist_production  TO kiosk_philslist;
GRANT CONNECT ON DATABASE kiosk_tudu_production       TO kiosk_tudu;
GRANT CONNECT ON DATABASE kiosk_prove_production      TO kiosk_prove;

-- NOTE (connections): Postgres max_connections >= Σ(app pools)
-- + headroom. At the shipped lean sizing each app pool =
-- WEB_CONCURRENCY(1) × RAILS_MAX_THREADS(5) = 5; all 8 apps = 40. Set
-- max_connections = 100 in postgresql.conf — that leaves room to double
-- WEB_CONCURRENCY later (8 apps × 2 × 5 = 80) plus admin headroom (or front
-- with PgBouncer if hosting all 8 on a 2 GB box). Not settable from this file.
