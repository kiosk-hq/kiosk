# frozen_string_literal: true

module Kiosk
  module Server
    # Pure SQL generators for the nine canonical Kiosk migrations.
    # Migrations 001-010, of which 003 is RETIRED:
    #
    #   001 create_kiosk_schema                → schema + four current_*() helpers
    #   002 create_kiosk_identity_tables       → agents, agent_tokens, agent_mappings
    #   003 — RETIRED 2026-08-20 (K-828). Was create_kiosk_actions_log
    #       (kiosk.actions, kiosk.action_log). Kiosk no longer stores an audit
    #       trail at all: it emits one {ActionEvent} per action invocation to
    #       the operator's `c.audit_sink` and keeps nothing. Phil: «Хранить в
    #       БД в рамках kiosk reference impl/demo не будем. Дадим интерфейс …
    #       и на его ответственность по PII.» The ORDINAL is left standing
    #       rather than renumbered: 004-010 are named by number in shipped
    #       comments, in CHANGELOG history and in adopters' own notes, and a
    #       renumber would make every one of those references silently wrong.
    #       The migrations are ordered by timestamp, not by this list.
    #   004 create_kiosk_reservations          → kiosk.reservations
    #   005 create_kiosk_device_authorizations → kiosk.device_authorizations (RFC 8628 Device Grant)
    #   006 create_kiosk_mandates              → intent_mandates, cart_mandates, payment_mandates, settlements (AP2 trail)
    #   007 add_kyc_verified_at                → kiosk.agents.kyc_verified_at column
    #   008 rebuild_kiosk_device_authorizations → device_authorizations in the
    #       account-binding shape (public_key_pem, kind, hashed user_code)
    #   009 create_kiosk_kyc_attributes         → kiosk.kyc_attributes, one ROW
    #       per named anonymized boolean a valid attestation granted an agent
    #       (additive, opt-in). Was a `kiosk.agents.kyc_attributes jsonb`
    #       column until 2026-08-20 (K-656/T-061); the ordinal is unchanged.
    #   010 add_kiosk_agent_governance_columns  → kiosk.agents.spending_cap_cents +
    #       .human_label (per-assistant governance; additive, opt-in)
    #
    # Pure functions: no database connection, no Rails dependency. Output
    # is SQL strings the host migration framework (`ActiveRecord::Migration#execute`)
    # runs. The shipped `kiosk:install` generator
    # (lib/generators/kiosk/install) copies ActiveRecord::Migration class
    # files into the host's `db/migrate/` that invoke these.
    module SchemaDefinitions
      module_function

      # ─── 001 create_kiosk_schema ───────────────────────────────────────

      # CREATE SCHEMA + four `<schema>.current_*()` STABLE helpers, typed
      # against the provider's user-id type.
      def helper_functions_sql(schema: nil, guc_namespace: nil, user_id_type: nil)
        schema       ||= Kiosk.configuration.schema
        guc_namespace ||= Kiosk.configuration.guc_namespace
        user_id_type  ||= Kiosk.configuration.user_id_type
        cast = user_id_cast(user_id_type)

        <<~SQL.strip
          CREATE SCHEMA IF NOT EXISTS "#{schema}";

          CREATE OR REPLACE FUNCTION "#{schema}".current_user_id() RETURNS #{cast} LANGUAGE sql STABLE AS $$
            SELECT NULLIF(current_setting('#{guc_namespace}.current_user_id', true), '')::#{cast}
          $$;

          CREATE OR REPLACE FUNCTION "#{schema}".current_role() RETURNS text LANGUAGE sql STABLE AS $$
            SELECT NULLIF(current_setting('#{guc_namespace}.current_role', true), '')
          $$;

          CREATE OR REPLACE FUNCTION "#{schema}".current_actor() RETURNS text LANGUAGE sql STABLE AS $$
            SELECT NULLIF(current_setting('#{guc_namespace}.current_actor', true), '')
          $$;

          CREATE OR REPLACE FUNCTION "#{schema}".current_agent_id() RETURNS uuid LANGUAGE sql STABLE AS $$
            SELECT NULLIF(current_setting('#{guc_namespace}.current_agent_id', true), '')::uuid
          $$;
        SQL
      end

      # ─── 002 create_kiosk_identity_tables ──────────────────────────────

      # `agents` — credential per (user × agent host); `agent_tokens` —
      # issued tokens for revocation; `agent_mappings` — external IdP
      # subject ↔ local `agent_id` mapping.
      def identity_tables_sql(schema: nil, user_id_type: nil, user_table: "users")
        schema      ||= Kiosk.configuration.schema
        user_id_type ||= Kiosk.configuration.user_id_type
        col_type = user_id_cast(user_id_type)

        <<~SQL.strip
          CREATE TABLE "#{schema}".agents (
            id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            user_id         #{col_type} NOT NULL REFERENCES "#{user_table}"(id) ON DELETE CASCADE,
            allowed_roles   text[] NOT NULL DEFAULT '{}'::text[],
            public_key      text,
            notification_pubkey text,
            created_at      timestamptz NOT NULL DEFAULT now(),
            revoked_at      timestamptz
          );
          CREATE INDEX idx_agents_user_id ON "#{schema}".agents (user_id) WHERE revoked_at IS NULL;
          -- Dedupe at the DB, not via SELECT-then-INSERT (TOCTOU): two LIVE
          -- rows for one public key cannot coexist. Partial (WHERE revoked_at
          -- IS NULL) so a revoked key can re-register.
          CREATE UNIQUE INDEX idx_agents_public_key_live
            ON "#{schema}".agents (public_key) WHERE revoked_at IS NULL;

          CREATE TABLE "#{schema}".agent_tokens (
            id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            agent_id    uuid NOT NULL REFERENCES "#{schema}".agents(id) ON DELETE CASCADE,
            token_hash  text NOT NULL,
            issued_at   timestamptz NOT NULL DEFAULT now(),
            expires_at  timestamptz NOT NULL,
            revoked_at  timestamptz
          );
          CREATE INDEX idx_agent_tokens_agent_id ON "#{schema}".agent_tokens (agent_id);
          CREATE UNIQUE INDEX idx_agent_tokens_hash ON "#{schema}".agent_tokens (token_hash);

          CREATE TABLE "#{schema}".agent_mappings (
            provider     text NOT NULL,
            external_id  text NOT NULL,
            agent_id     uuid NOT NULL REFERENCES "#{schema}".agents(id) ON DELETE CASCADE,
            PRIMARY KEY (provider, external_id)
          );
        SQL
      end

      # ─── 003 create_kiosk_actions_log — RETIRED, no generator ──────────
      #
      # `actions_log_sql` used to emit `kiosk.actions` + `kiosk.action_log`
      # here. It is GONE, not deprecated: nothing writes those tables since
      # K-828 reversed the audit trail into an operator-owned sink
      # ({Kiosk::Server::AuditSink}), and a shipped migration that creates an
      # audit table nothing ever fills is exactly the defect K-791 filed in
      # the first place. There are no adopters to carry a compatibility shim
      # for; an existing installation drops the two tables by hand.

      # ─── 004 create_kiosk_reservations ─────────────────────────────────

      # Atomic reserve-then-pay primitive. TTL row in `kiosk.reservations`
      # holds inventory while AP2 mandate trail completes; expiry releases
      # automatically.
      def reservations_sql(schema: nil, user_id_type: nil)
        schema      ||= Kiosk.configuration.schema
        user_id_type ||= Kiosk.configuration.user_id_type
        col_type = user_id_cast(user_id_type)

        <<~SQL.strip
          CREATE TABLE "#{schema}".reservations (
            id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            user_id       #{col_type} NOT NULL,
            agent_id      uuid,
            resource_kind text NOT NULL,
            resource_id   text NOT NULL,
            args          jsonb NOT NULL DEFAULT '{}'::jsonb,
            reserved_at   timestamptz NOT NULL DEFAULT now(),
            expires_at    timestamptz NOT NULL,
            released_at   timestamptz,
            CONSTRAINT reservations_unique_active
              UNIQUE (resource_kind, resource_id, released_at)
              DEFERRABLE INITIALLY DEFERRED
          );
          CREATE INDEX idx_reservations_user_id  ON "#{schema}".reservations (user_id);
          CREATE INDEX idx_reservations_expiry   ON "#{schema}".reservations (expires_at) WHERE released_at IS NULL;
        SQL
      end

      # ─── 005 create_kiosk_device_authorizations ───────────────────────

      # DDL for the RFC 8628 Device Authorization Grant state machine table:
      # one row per device-authorization request — created on
      # /oauth/device_authorization, mutated by /oauth/device/verify
      # (approve/deny), consumed by /oauth/token (device_code grant).
      #
      # NOTE (historical): 0.1 shipped this table unused — no durable
      # adapter existed and the InMemory store served the (dormant)
      # endpoints, so shipped code never read or wrote it. Migration 008
      # ({.rebuild_device_authorizations_sql}) rebuilds it in the
      # account-binding shape that the shipped
      # {DeviceAuthorizationStores::ActiveRecord} adapter reads and writes;
      # this 005 form is kept for migration-history fidelity.
      #
      # device_code_hash carries SHA-256 of the actual device_code; the
      # plain code lives only in the response body to the initiating
      # client and is never persisted server-side. user_code is the
      # human-displayable short token (Crockford alphabet, 8 chars,
      # XXXX-XXXX format).
      def device_authorizations_sql(schema: nil, user_id_type: nil)
        schema      ||= Kiosk.configuration.schema
        user_id_type ||= Kiosk.configuration.user_id_type
        col_type = user_id_cast(user_id_type)

        <<~SQL.strip
          CREATE TABLE "#{schema}".device_authorizations (
            id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            device_code_hash bytea NOT NULL,
            user_code        text  NOT NULL,
            client_id        text  NOT NULL,
            requested_role   text,
            status           text  NOT NULL,
            user_id          #{col_type},
            expires_at       timestamptz NOT NULL,
            consumed_at      timestamptz,
            created_at       timestamptz NOT NULL DEFAULT now(),
            CONSTRAINT device_authorizations_status_check
              CHECK (status IN ('pending', 'approved', 'denied', 'consumed', 'expired'))
          );
          CREATE UNIQUE INDEX idx_device_authorizations_code_hash
            ON "#{schema}".device_authorizations (device_code_hash);
          -- Only `pending` rows need a unique user_code; approved/consumed
          -- rows may share codes from past flows without collision.
          CREATE UNIQUE INDEX idx_device_authorizations_user_code_pending
            ON "#{schema}".device_authorizations (user_code)
            WHERE status = 'pending';
          CREATE INDEX idx_device_authorizations_expiry
            ON "#{schema}".device_authorizations (expires_at)
            WHERE status IN ('pending', 'approved');
        SQL
      end

      # ─── 006 create_kiosk_mandates ─────────────────────────────────────

      # AP2 mandate trail: three signed mandate tables — `intent_mandates`
      # (spending envelope signed by the user), `cart_mandates`
      # (agent-assembled cart within the envelope), `payment_mandates`
      # (assistant-signed payment mandate carrying the payment instrument) —
      # plus `settlements` (PSP settlement receipt). Each signed-mandate row
      # carries its original JWS so the chain is auditable end-to-end.
      #
      # `id` is a SERVER-generated uuid PK (`gen_random_uuid()`) — never
      # supplied by the caller, so one principal cannot pre-occupy or block
      # another's row on these (currently RLS-less) tables. The agent-signed
      # mandate id lives in `mandate_id text NOT NULL` for audit + idempotency,
      # made unique PER PRINCIPAL via `UNIQUE (user_id, mandate_id)`. The FK
      # chain references the SERVER ids; `UNIQUE (cart_mandate_id)` on
      # settlements anchors one settlement per cart.
      def mandates_sql(schema: nil, user_id_type: nil)
        schema       ||= Kiosk.configuration.schema
        user_id_type ||= Kiosk.configuration.user_id_type
        col_type = user_id_cast(user_id_type)

        <<~SQL.strip
          CREATE TABLE "#{schema}".intent_mandates (
            id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            mandate_id        text NOT NULL,
            user_id           #{col_type} NOT NULL,
            agent_id          uuid NOT NULL,
            issuer            text NOT NULL,
            scope             text NOT NULL,
            cap_amount_cents  bigint NOT NULL,
            currency          text NOT NULL,
            expires_at        timestamptz NOT NULL,
            created_at        timestamptz NOT NULL DEFAULT now(),
            raw_jws           text NOT NULL,
            UNIQUE (user_id, mandate_id)
          );
          CREATE INDEX idx_intent_mandates_user_id  ON "#{schema}".intent_mandates (user_id);
          CREATE INDEX idx_intent_mandates_agent_id ON "#{schema}".intent_mandates (agent_id);

          CREATE TABLE "#{schema}".cart_mandates (
            id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            mandate_id         text NOT NULL,
            intent_mandate_id  uuid NOT NULL REFERENCES "#{schema}".intent_mandates(id) ON DELETE CASCADE,
            user_id            #{col_type} NOT NULL,
            agent_id           uuid NOT NULL,
            issuer             text NOT NULL,
            line_items         jsonb NOT NULL,
            total_amount_cents bigint NOT NULL,
            currency           text NOT NULL,
            expires_at         timestamptz NOT NULL,
            created_at         timestamptz NOT NULL DEFAULT now(),
            raw_jws            text NOT NULL,
            UNIQUE (user_id, mandate_id)
          );
          CREATE INDEX idx_cart_mandates_user_id ON "#{schema}".cart_mandates (user_id);
          CREATE INDEX idx_cart_mandates_intent  ON "#{schema}".cart_mandates (intent_mandate_id);

          CREATE TABLE "#{schema}".payment_mandates (
            id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            mandate_id       text NOT NULL,
            cart_mandate_id  uuid NOT NULL REFERENCES "#{schema}".cart_mandates(id) ON DELETE CASCADE,
            user_id          #{col_type} NOT NULL,
            agent_id         uuid NOT NULL,
            issuer           text NOT NULL,
            payment_method   text NOT NULL,
            amount_cents     bigint NOT NULL,
            currency         text NOT NULL,
            expires_at       timestamptz,
            created_at       timestamptz NOT NULL DEFAULT now(),
            raw_jws          text NOT NULL,
            UNIQUE (user_id, mandate_id)
          );
          CREATE INDEX idx_payment_mandates_user_id ON "#{schema}".payment_mandates (user_id);
          CREATE INDEX idx_payment_mandates_cart    ON "#{schema}".payment_mandates (cart_mandate_id);

          CREATE TABLE "#{schema}".settlements (
            id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            cart_mandate_id      uuid NOT NULL REFERENCES "#{schema}".cart_mandates(id) ON DELETE CASCADE,
            user_id              #{col_type} NOT NULL,
            agent_id             uuid NOT NULL,
            issuer               text NOT NULL,
            psp_reference        text NOT NULL,
            settled_amount_cents bigint NOT NULL,
            currency             text NOT NULL,
            settled_at           timestamptz NOT NULL,
            raw_jws              text NOT NULL,
            UNIQUE (cart_mandate_id)
          );
          CREATE INDEX idx_settlements_user_id ON "#{schema}".settlements (user_id);
          CREATE INDEX idx_settlements_cart    ON "#{schema}".settlements (cart_mandate_id);
        SQL
      end

      # ─── 007 add_kyc_verified_at ───────────────────────────────────────

      # Adds `kyc_verified_at timestamptz` to `kiosk.agents`.
      # Idempotent (ADD COLUMN IF NOT EXISTS) — safe to re-run.
      # A non-NULL value means the agent has passed KYC attestation.
      def kyc_verified_at_sql(schema: nil)
        schema ||= Kiosk.configuration.schema

        <<~SQL.strip
          ALTER TABLE "#{schema}".agents
            ADD COLUMN IF NOT EXISTS kyc_verified_at timestamptz;
        SQL
      end

      # ─── 009 create_kiosk_kyc_attributes ───────────────────────────────

      # `kyc_attributes` — ONE ROW per NAMED ANONYMIZED boolean a valid KYC
      # attestation granted an agent (`age_over_18`, `licence_a`, ...). Only
      # the NAMES are stored — never the DOB, licence number, or any underlying
      # document, which is the anonymized property ADR-0020 exists for.
      #
      # A TABLE, not the `agents.kyc_attributes jsonb` column this ordinal
      # created until 2026-08-20 (decision KYC-ATTRIBUTES-TABLE, Phil
      # 2026-08-12; K-656/T-061). The ordinal keeps its number for the same
      # reason 003 kept its own: 004-010 are named by number in shipped
      # comments and in CHANGELOG history.
      #
      # THERE IS NO VALUE COLUMN, AND THAT IS THE POINT. The grant IS the row:
      # an attribute is granted iff `(agent_id, name)` exists. A jsonb map had
      # to carry a value, and a value has spellings — JSON `true`, the STRING
      # `"true"`, `1` — so every reader had to decide which spellings count and
      # each reader could decide differently (getgrocery and skooti both pushed
      # that test into Postgres, as `COALESCE(kyc_attributes ->> 'name',
      # 'false')`, precisely because a Ruby `== true` would accept one spelling
      # and silently refuse the other inside a KYC gate). With presence as the
      # grant there is nothing to spell: every gate is an EXISTS, which cannot
      # return NULL and cannot be fooled by a truthy-but-not-`true` value. The
      # one place a spelling is still judged is the WRITE — see
      # {KycAttestationController#mark_kyc_verified!}, which selects the names
      # to insert with `WHERE value = 'true'::jsonb`, in Postgres, once, for
      # every operator.
      #
      # `ON DELETE CASCADE` from `agents`: a deleted agent takes its grants with
      # it. Additive: providers that only need the binary `kyc_verified_at` gate
      # can skip this migration.
      def kyc_attributes_sql(schema: nil)
        schema ||= Kiosk.configuration.schema

        <<~SQL.strip
          CREATE TABLE "#{schema}".kyc_attributes (
            agent_id   uuid NOT NULL REFERENCES "#{schema}".agents(id) ON DELETE CASCADE,
            name       text NOT NULL,
            granted_at timestamptz NOT NULL DEFAULT now(),
            PRIMARY KEY (agent_id, name)
          );
        SQL
      end

      # Adds the per-assistant governance columns to `kiosk.agents`:
      #   `spending_cap_cents bigint` — per-assistant spend cap; NULL = unlimited
      #     (the default), 0 = disabled. Enforced by the pay path via the
      #     `config.spending_cap` seam ({ColumnSpendingCap} reads this column).
      #   `human_label text` — a human-friendly name for the manage-assistants page.
      # Idempotent (ADD COLUMN IF NOT EXISTS) — safe to re-run. Opt-in: a provider
      # only needs this migration if it enables per-assistant caps/labels.
      def agent_governance_columns_sql(schema: nil)
        schema ||= Kiosk.configuration.schema

        <<~SQL.strip
          ALTER TABLE "#{schema}".agents
            ADD COLUMN IF NOT EXISTS spending_cap_cents bigint,
            ADD COLUMN IF NOT EXISTS human_label        text;
        SQL
      end

      # ─── 008 rebuild_kiosk_device_authorizations (account binding) ─────

      # Rebuilds `kiosk.device_authorizations` in the account-binding shape
      # read/written by {DeviceAuthorizationStores::ActiveRecord},
      # the default store:
      #
      #   - `user_code` (plaintext) → `user_code_hash` — codes are stored
      #     hashed ONLY (SHA-256 hex, matching `agent_tokens.token_hash`);
      #   - `device_code_hash` becomes text (hex digest, was bytea);
      #   - `public_key_pem` — the key the ceremony binds (BIND-POP proves
      #     possession of it before any binding);
      #   - `kind` — `claim` (agent-initiated) or `link` (human-initiated,
      #     rows born pre-approved and already bound to the human).
      #
      # DROP + CREATE, not ALTER: the 005 table was created-but-never-written
      # by shipped 0.1 code (see the 005 NOTE), so recreation is lossless.
      def rebuild_device_authorizations_sql(schema: nil, user_id_type: nil)
        schema      ||= Kiosk.configuration.schema
        user_id_type ||= Kiosk.configuration.user_id_type
        col_type = user_id_cast(user_id_type)

        <<~SQL.strip
          DROP TABLE IF EXISTS "#{schema}".device_authorizations;

          CREATE TABLE "#{schema}".device_authorizations (
            id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            device_code_hash text NOT NULL,
            user_code_hash   text NOT NULL,
            public_key_pem   text,
            kind             text NOT NULL DEFAULT 'claim',
            client_id        text NOT NULL,
            requested_role   text,
            status           text NOT NULL,
            user_id          #{col_type},
            expires_at       timestamptz NOT NULL,
            consumed_at      timestamptz,
            created_at       timestamptz NOT NULL DEFAULT now(),
            CONSTRAINT device_authorizations_status_check
              CHECK (status IN ('pending', 'approved', 'denied', 'consumed', 'expired')),
            CONSTRAINT device_authorizations_kind_check
              CHECK (kind IN ('claim', 'link'))
          );
          CREATE UNIQUE INDEX idx_device_authorizations_code_hash
            ON "#{schema}".device_authorizations (device_code_hash);
          -- Only `pending` rows need a unique user_code; approved/consumed
          -- rows may share codes from past flows without collision.
          CREATE UNIQUE INDEX idx_device_authorizations_user_code_pending
            ON "#{schema}".device_authorizations (user_code_hash)
            WHERE status = 'pending';
          CREATE INDEX idx_device_authorizations_expiry
            ON "#{schema}".device_authorizations (expires_at)
            WHERE status IN ('pending', 'approved');
        SQL
      end

      # ─── optional: shared PoW spent-id table (NOT a canonical migration) ─

      # Table backing {PowSpentStores::ActiveRecord}, the shared spent-id
      # store a MULTI-PROCESS operator must configure so that PoW single-use
      # holds across web workers (K-738).
      #
      # This is deliberately NOT one of the ten canonical migrations and the
      # `kiosk:install` generator does not lay it down: the shipped default
      # store is in-process ({PowSpentStore}) and a single-process operator
      # needs no table at all. An operator raising `WEB_CONCURRENCY` above 1
      # adds a one-line migration of their own that calls this — see the
      # "Multi-process deployments" section of the kiosk-server README.
      #
      # `id` is the opaque challenge id (Section 10 of the protocol), so the
      # PRIMARY KEY is the single-use gate itself: the store's `claim` is one
      # `INSERT … ON CONFLICT (id) DO UPDATE … WHERE expires_at <= now()`
      # statement, and the unique index — not application code — decides who
      # won. `expires_at` mirrors the challenge `exp`; rows past it are
      # reclaimable (challenge ids are random, so this only matters for
      # pruning) and {PowSpentStores::ActiveRecord#prune!} deletes them.
      def pow_spent_sql(schema: nil)
        schema ||= Kiosk.configuration.schema

        <<~SQL.strip
          CREATE TABLE "#{schema}".pow_spent (
            id         text        PRIMARY KEY,
            expires_at timestamptz NOT NULL
          );
          -- Supports the TTL sweep only; the PK above is what enforces
          -- single-use.
          CREATE INDEX idx_pow_spent_expires_at
            ON "#{schema}".pow_spent (expires_at);
        SQL
      end

      # ─── helpers ───────────────────────────────────────────────────────

      def user_id_cast(user_id_type)
        case user_id_type.to_sym
        when :uuid               then "uuid"
        when :bigint, :integer   then user_id_type.to_s
        when :text               then "text"
        else
          raise ArgumentError,
                "user_id_type must be one of :uuid, :bigint, :integer, :text — got #{user_id_type.inspect}"
        end
      end
    end
  end
end
