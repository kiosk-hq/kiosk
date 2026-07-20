-- Kiosk hosted live demos — Postgres provisioning (T-032)
-- Design: meta/docs/architecture/2026-07-20-hosted-live-demos.md §1
--
-- ONE Postgres 16 cluster, one database + one least-privilege LOGIN role per
-- hosted app (DB-per-app). Each demo's config/database.yml (production block)
-- expects db  kiosk_<app>_production  owned by role  kiosk_<app>  and
-- authenticates as KIOSK_<APP>_DB_USER / KIOSK_<APP>_DB_PASSWORD.
--
-- HOW TO RUN (as the cluster superuser, e.g. postgres):
--   psql -v ON_ERROR_STOP=1 \
--        -v gg_pw="'…'"  -v af_pw="'…'"  -v ho_pw="'…'"  -v sk_pw="'…'" \
--        -v st_pw="'…'"  -v pl_pw="'…'"  -v td_pw="'…'" \
--        -f postgres-init.sql
--
-- Pass each password as a quoted psql variable (note the inner single quotes:
--   -v gg_pw="'S3cret!'"  ). Use the SAME value in env/<app>.env
-- (KIOSK_<APP>_DB_PASSWORD). Never commit real passwords.
--
-- Idempotent-ish: roles/dbs are created with guards so re-running is safe.
-- Run once at provisioning; re-run only adds what is missing.

\set ON_ERROR_STOP on

-- ── Roles (LOGIN, no CREATEDB/SUPERUSER — least privilege) ──────────────────
-- gen: DO block so CREATE ROLE is skipped if the role already exists.

DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'kiosk_getgrocery') THEN
    CREATE ROLE kiosk_getgrocery LOGIN PASSWORD :gg_pw;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'kiosk_atablefor') THEN
    CREATE ROLE kiosk_atablefor LOGIN PASSWORD :af_pw;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'kiosk_hoteling') THEN
    CREATE ROLE kiosk_hoteling LOGIN PASSWORD :ho_pw;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'kiosk_skooti') THEN
    CREATE ROLE kiosk_skooti LOGIN PASSWORD :sk_pw;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'kiosk_stylish') THEN
    CREATE ROLE kiosk_stylish LOGIN PASSWORD :st_pw;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'kiosk_philslist') THEN
    CREATE ROLE kiosk_philslist LOGIN PASSWORD :pl_pw;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'kiosk_tudu') THEN
    CREATE ROLE kiosk_tudu LOGIN PASSWORD :td_pw;
  END IF;
END $$;

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

-- ── Ownership / privilege hardening ─────────────────────────────────────────
-- Each app role owns its own DB (set above) so `db:prepare` can create the
-- `kiosk` schema, tables and (opt-in) RLS policies. No app role is granted on
-- any other app's DB — cross-tenant isolation at the cluster boundary, on top
-- of the per-agent app-layer isolation (design §2.2). Revoke PUBLIC connect so
-- only the owning role reaches each DB.

REVOKE CONNECT ON DATABASE kiosk_getgrocery_production FROM PUBLIC;
REVOKE CONNECT ON DATABASE kiosk_atablefor_production FROM PUBLIC;
REVOKE CONNECT ON DATABASE kiosk_hoteling_production  FROM PUBLIC;
REVOKE CONNECT ON DATABASE kiosk_skooti_production    FROM PUBLIC;
REVOKE CONNECT ON DATABASE kiosk_stylish_production   FROM PUBLIC;
REVOKE CONNECT ON DATABASE kiosk_philslist_production FROM PUBLIC;
REVOKE CONNECT ON DATABASE kiosk_tudu_production      FROM PUBLIC;

GRANT CONNECT ON DATABASE kiosk_getgrocery_production TO kiosk_getgrocery;
GRANT CONNECT ON DATABASE kiosk_atablefor_production  TO kiosk_atablefor;
GRANT CONNECT ON DATABASE kiosk_hoteling_production   TO kiosk_hoteling;
GRANT CONNECT ON DATABASE kiosk_skooti_production     TO kiosk_skooti;
GRANT CONNECT ON DATABASE kiosk_stylish_production    TO kiosk_stylish;
GRANT CONNECT ON DATABASE kiosk_philslist_production  TO kiosk_philslist;
GRANT CONNECT ON DATABASE kiosk_tudu_production       TO kiosk_tudu;

-- NOTE (connections): design §2 sizes Postgres max_connections >= Σ(app pools)
-- + headroom. Each app pool = WEB_CONCURRENCY(2) × RAILS_MAX_THREADS(5) = 10;
-- all 7 apps = 70. Set  max_connections = 100  in postgresql.conf (or front
-- with PgBouncer if hosting all 7 on a 2 GB box). Not settable from this file.
