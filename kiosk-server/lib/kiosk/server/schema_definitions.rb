# frozen_string_literal: true

module Kiosk
  module Server
    # Pure SQL generators for the ten canonical Kiosk migrations.
    # Migrations 001-010:
    #
    #   001 create_kiosk_schema                → schema + four current_*() helpers
    #   002 create_kiosk_identity_tables       → agents, agent_tokens, agent_mappings
    #   003 create_kiosk_actions_log           → kiosk.actions, kiosk.action_log
    #   004 create_kiosk_reservations          → kiosk.reservations
    #   005 create_kiosk_device_authorizations → kiosk.device_authorizations (RFC 8628 Device Grant)
    #   006 create_kiosk_mandates              → intent_mandates, cart_mandates, payment_mandates, settlements (AP2 trail)
    #   007 add_kyc_verified_at                → kiosk.agents.kyc_verified_at column
    #   008 rebuild_kiosk_device_authorizations → device_authorizations in the
    #       account-binding shape (public_key_pem, kind, hashed user_code)
    #   009 add_kyc_attributes                  → kiosk.agents.kyc_attributes jsonb
    #       (named anonymized boolean attributes; additive, opt-in)
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

      # ─── 003 create_kiosk_actions_log ──────────────────────────────────

      # `kiosk.actions` registers known Action names; `kiosk.action_log`
      # records each invocation with the principal+agent+role.
      #
      # WRITTEN BY {ActionLog}, from the `run` branch of {Executor#call}: one
      # row per action invocation, success or failure, after the action's own
      # transaction closes. Until T-088 nothing wrote either table and an
      # adopter carried an audit surface whose emptiness read as «no actions
      # were invoked» (K-791); `kiosk.actions` is the FK anchor and is upserted
      # from the live registry by the same writer.
      #
      # NO RLS, and that is deliberate rather than an omission — this comment
      # used to claim «RLS-enabled by the calling migration so users see only
      # their own», which no shipped migration has ever done. The log crosses
      # principals BY DESIGN: it is the operator's oversight surface, a policy
      # scoping it to `current_user_id()` would hide rows from the operator who
      # needs to read them, and an audit table a caller's own session could
      # read is one it could enumerate. The writer opens no {SessionContext},
      # so rows are written as the connection's own role and a caller's session
      # can neither suppress nor forge one. See {ActionLog}.
      def actions_log_sql(schema: nil, user_id_type: nil)
        schema      ||= Kiosk.configuration.schema
        user_id_type ||= Kiosk.configuration.user_id_type
        col_type = user_id_cast(user_id_type)

        <<~SQL.strip
          CREATE TABLE "#{schema}".actions (
            name         text PRIMARY KEY,
            description  text,
            created_at   timestamptz NOT NULL DEFAULT now()
          );

          CREATE TABLE "#{schema}".action_log (
            id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            action_name   text NOT NULL REFERENCES "#{schema}".actions(name),
            user_id       #{col_type} NOT NULL,
            agent_id      uuid,
            role          text NOT NULL,
            actor         text NOT NULL,
            args          jsonb NOT NULL DEFAULT '{}'::jsonb,
            result_status text NOT NULL,
            error_class   text,
            error_message text,
            invoked_at    timestamptz NOT NULL DEFAULT now()
          );
          CREATE INDEX idx_action_log_user_id   ON "#{schema}".action_log (user_id, invoked_at DESC);
          CREATE INDEX idx_action_log_agent_id  ON "#{schema}".action_log (agent_id, invoked_at DESC) WHERE agent_id IS NOT NULL;
        SQL
      end

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

      # Adds `kyc_attributes jsonb` to `kiosk.agents` — the set of NAMED
      # ANONYMIZED boolean attributes a valid KYC attestation granted (e.g.
      # `{"age_over_18": true, "licence_a": true}`). NULL until the agent
      # submits an attestation; a bare binary attestation with no attributes
      # writes `{}`. Only the booleans are stored — never the DOB, licence
      # number, or any underlying document. Idempotent (ADD COLUMN IF NOT
      # EXISTS) — safe to re-run. Additive: providers that only need the binary
      # `kyc_verified_at` gate can skip this migration.
      def kyc_attributes_sql(schema: nil)
        schema ||= Kiosk.configuration.schema

        <<~SQL.strip
          ALTER TABLE "#{schema}".agents
            ADD COLUMN IF NOT EXISTS kyc_attributes jsonb;
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
