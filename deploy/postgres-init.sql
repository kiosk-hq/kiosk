-- Kiosk hosted live demos — Postgres provisioning
--
-- ONE Postgres 17 cluster, one database + one least-privilege LOGIN role per
-- hosted app (DB-per-app). Each demo's config/database.yml (production block)
-- reads its database name from  KIOSK_<APP>_DB  (default kiosk_<app>_production)
-- and authenticates as KIOSK_<APP>_DB_USER (default kiosk_<app>) /
-- KIOSK_<APP>_DB_PASSWORD.
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
-- NAME OVERRIDES: the database and role names below are NOT hardcoded —
-- each is a psql variable that defaults to the shipped name, so the command
-- above (passwords only) provisions exactly what it always did. If you change an
-- app's KIOSK_<APP>_DB / KIOSK_<APP>_DB_USER in env/<app>.env, pass the SAME
-- value here so provisioning creates what the app will connect to:
--   app         env var                        psql var        default
--   getgrocery  KIOSK_GETGROCERY_DB            -v gg_db=       kiosk_getgrocery_production
--               KIOSK_GETGROCERY_DB_USER       -v gg_user=     kiosk_getgrocery
--   atablefor   KIOSK_ATABLEFOR_DB / _DB_USER  -v af_db= / af_user=
--   hoteling    KIOSK_HOTELING_DB  / _DB_USER  -v ho_db= / ho_user=
--   skooti      KIOSK_SKOOTI_DB    / _DB_USER  -v sk_db= / sk_user=
--   stylish     KIOSK_STYLISH_DB   / _DB_USER  -v st_db= / st_user=
--   philslist   KIOSK_PHILSLIST_DB / _DB_USER  -v pl_db= / pl_user=
--   tudu        KIOSK_TUDU_DB      / _DB_USER  -v td_db= / td_user=
--   prove       KIOSK_PROVE_DB     / _DB_USER  -v pv_db= / pv_user=
-- (psql cannot read the env files itself — they are per-app and are sourced by
-- systemd, not by this superuser shell — so the two sides are kept in sync by
-- hand. Override nothing and there is nothing to keep in sync.)
--
-- Idempotent-ish: roles/dbs are created with guards so re-running is safe.
-- Run once at provisioning; re-run only adds what is missing.

\set ON_ERROR_STOP on

-- ── Name resolution (default unless overridden with -v on the command line) ──
-- `:{?var}` is true only when the variable was supplied, so each \set below is
-- a "default if absent". Every name is spliced into DDL with format(%I), which
-- quotes and escapes identifiers safely.

\if :{?gg_db} \else \set gg_db kiosk_getgrocery_production \endif
\if :{?af_db} \else \set af_db kiosk_atablefor_production \endif
\if :{?ho_db} \else \set ho_db kiosk_hoteling_production \endif
\if :{?sk_db} \else \set sk_db kiosk_skooti_production \endif
\if :{?st_db} \else \set st_db kiosk_stylish_production \endif
\if :{?pl_db} \else \set pl_db kiosk_philslist_production \endif
\if :{?td_db} \else \set td_db kiosk_tudu_production \endif
\if :{?pv_db} \else \set pv_db kiosk_prove_production \endif

\if :{?gg_user} \else \set gg_user kiosk_getgrocery \endif
\if :{?af_user} \else \set af_user kiosk_atablefor \endif
\if :{?ho_user} \else \set ho_user kiosk_hoteling \endif
\if :{?sk_user} \else \set sk_user kiosk_skooti \endif
\if :{?st_user} \else \set st_user kiosk_stylish \endif
\if :{?pl_user} \else \set pl_user kiosk_philslist \endif
\if :{?td_user} \else \set td_user kiosk_tudu \endif
\if :{?pv_user} \else \set pv_user kiosk_prove \endif

-- ── Roles (LOGIN, no CREATEDB/SUPERUSER — least privilege) ──────────────────
-- Idempotent per-role create in the OUTER SQL so \gexec can interpolate the
-- password variable. (A CREATE ROLE inside a DO/dollar-quoted block can NOT use
-- a :var — psql does not substitute variables inside dollar-quoted strings, so
-- the literal ":gg_pw" would reach the server and error "syntax error at :".)
-- Each password is spliced with :'var' quote-substitution, which single-quotes
-- and escapes it safely; the WHERE NOT EXISTS guard skips roles that already
-- exist, so re-running is a no-op.

SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'gg_user', :'gg_pw')
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'gg_user')\gexec
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'af_user', :'af_pw')
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'af_user')\gexec
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'ho_user', :'ho_pw')
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'ho_user')\gexec
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'sk_user', :'sk_pw')
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'sk_user')\gexec
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'st_user', :'st_pw')
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'st_user')\gexec
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'pl_user', :'pl_pw')
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'pl_user')\gexec
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'td_user', :'td_pw')
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'td_user')\gexec
-- KYC broker (gem dir kiosk-demo-prove; deploy domain kyc.demo.kiosk.tech)
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'pv_user', :'pv_pw')
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'pv_user')\gexec

-- ── Databases (one per app, owned by its role) ──────────────────────────────
-- CREATE DATABASE cannot run inside a transaction/DO block, and \gexec lets us
-- guard on existence. Each db is owned by its matching least-privilege role.

SELECT format('CREATE DATABASE %I OWNER %I', :'gg_db', :'gg_user')
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'gg_db')\gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'af_db', :'af_user')
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'af_db')\gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'ho_db', :'ho_user')
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'ho_db')\gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'sk_db', :'sk_user')
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'sk_db')\gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'st_db', :'st_user')
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'st_db')\gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'pl_db', :'pl_user')
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'pl_db')\gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'td_db', :'td_user')
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'td_db')\gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'pv_db', :'pv_user')
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'pv_db')\gexec

-- ── Ownership / privilege hardening ─────────────────────────────────────────
-- Each app role owns its own DB (set above) so `db:prepare` can create the
-- `kiosk` schema, tables and (opt-in) RLS policies. No app role is granted on
-- any other app's DB — cross-tenant isolation at the cluster boundary, on top
-- of the per-agent app-layer isolation. Revoke PUBLIC connect so
-- only the owning role reaches each DB.

SELECT format('REVOKE CONNECT ON DATABASE %I FROM PUBLIC', :'gg_db')\gexec
SELECT format('REVOKE CONNECT ON DATABASE %I FROM PUBLIC', :'af_db')\gexec
SELECT format('REVOKE CONNECT ON DATABASE %I FROM PUBLIC', :'ho_db')\gexec
SELECT format('REVOKE CONNECT ON DATABASE %I FROM PUBLIC', :'sk_db')\gexec
SELECT format('REVOKE CONNECT ON DATABASE %I FROM PUBLIC', :'st_db')\gexec
SELECT format('REVOKE CONNECT ON DATABASE %I FROM PUBLIC', :'pl_db')\gexec
SELECT format('REVOKE CONNECT ON DATABASE %I FROM PUBLIC', :'td_db')\gexec
SELECT format('REVOKE CONNECT ON DATABASE %I FROM PUBLIC', :'pv_db')\gexec

SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'gg_db', :'gg_user')\gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'af_db', :'af_user')\gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'ho_db', :'ho_user')\gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'sk_db', :'sk_user')\gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'st_db', :'st_user')\gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'pl_db', :'pl_user')\gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'td_db', :'td_user')\gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'pv_db', :'pv_user')\gexec

-- NOTE (connections): Postgres max_connections >= Σ(app pools)
-- + headroom. At the shipped lean sizing each app pool =
-- WEB_CONCURRENCY(1) × RAILS_MAX_THREADS(5) = 5; all 8 apps = 40. Set
-- max_connections = 100 in postgresql.conf — that leaves room to double
-- WEB_CONCURRENCY later (8 apps × 2 × 5 = 80) plus admin headroom (or front
-- with PgBouncer if hosting all 8 on a 2 GB box). Not settable from this file.
