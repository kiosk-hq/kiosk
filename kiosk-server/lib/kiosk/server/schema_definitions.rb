# frozen_string_literal: true

module Kiosk
  module Server
    # The SQL of the migrations `kiosk:install` emits, one method per
    # migration, each creating its tables in their final shape. No database
    # connection; the host's migrations `execute` it.
    # rubocop:disable-next Metrics/ModuleLength, Metrics/MethodLength -- each method returns one migration's DDL as one SQL heredoc
    module SchemaDefinitions
      module_function

      # 001: the schema and the `current_*()` GUC readers.
      def helper_functions_sql(schema: nil, guc_namespace: nil, user_id_type: nil)
        schema ||= Kiosk.configuration.schema
        guc_namespace ||= Kiosk.configuration.guc_namespace
        user_id_type  ||= Kiosk.configuration.user_id_type
        cast = user_id_cast(user_id_type)

        <<~DDL.strip
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
        DDL
      end

      # 002: `agents` (`spending_cap_cents`: NULL unlimited, 0 disabled; a cap
      # has its `spending_cap_currency`), `agent_tokens`, `agent_mappings`.
      def identity_tables_sql(schema: nil, user_id_type: nil, user_table: 'users')
        schema ||= Kiosk.configuration.schema
        user_id_type ||= Kiosk.configuration.user_id_type
        col_type = user_id_cast(user_id_type)

        <<~DDL.strip
          CREATE TABLE IF NOT EXISTS "#{schema}".agents (
            id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            user_id             #{col_type} NOT NULL REFERENCES "#{user_table}"(id) ON DELETE CASCADE,
            allowed_roles       text[] NOT NULL DEFAULT '{}'::text[],
            public_key          text,
            human_label         text,
            spending_cap_cents  bigint,
            spending_cap_currency text CHECK (spending_cap_currency ~ '^[a-z]{3}$'),
            created_at          timestamptz NOT NULL DEFAULT now(),
            revoked_at          timestamptz,
            issuer              text NOT NULL,
            CONSTRAINT agents_spending_cap_currency_set
              CHECK ((spending_cap_cents IS NULL) = (spending_cap_currency IS NULL))
          );

          CREATE INDEX IF NOT EXISTS idx_agents_user_id ON "#{schema}".agents (user_id) WHERE revoked_at IS NULL;
          -- Dedupe at the DB, not via SELECT-then-INSERT (TOCTOU): two LIVE
          -- rows for one public key on one origin cannot coexist. Partial
          -- (WHERE revoked_at IS NULL) so a revoked key can re-register.
          CREATE UNIQUE INDEX IF NOT EXISTS idx_agents_issuer_public_key_live
            ON "#{schema}".agents (issuer, public_key) WHERE revoked_at IS NULL;

          CREATE TABLE IF NOT EXISTS "#{schema}".agent_tokens (
            id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            agent_id    uuid NOT NULL REFERENCES "#{schema}".agents(id) ON DELETE CASCADE,
            token_hash  text NOT NULL,
            issued_at   timestamptz NOT NULL DEFAULT now(),
            expires_at  timestamptz NOT NULL,
            revoked_at  timestamptz
          );
          CREATE INDEX IF NOT EXISTS idx_agent_tokens_agent_id ON "#{schema}".agent_tokens (agent_id);
          CREATE UNIQUE INDEX IF NOT EXISTS idx_agent_tokens_hash ON "#{schema}".agent_tokens (token_hash);

          CREATE TABLE IF NOT EXISTS "#{schema}".agent_mappings (
            provider     text NOT NULL,
            external_id  text NOT NULL,
            agent_id     uuid NOT NULL REFERENCES "#{schema}".agents(id) ON DELETE CASCADE,
            PRIMARY KEY (provider, external_id)
          );
        DDL
      end

      # 004: account-binding requests; codes are stored hashed only.
      # `requested_role` is the approving human's role, never a client's.
      def device_authorizations_sql(schema: nil, user_id_type: nil)
        schema ||= Kiosk.configuration.schema
        user_id_type ||= Kiosk.configuration.user_id_type
        col_type = user_id_cast(user_id_type)

        <<~DDL.strip
          CREATE TABLE IF NOT EXISTS "#{schema}".device_authorizations (
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
          CREATE UNIQUE INDEX IF NOT EXISTS idx_device_authorizations_code_hash
            ON "#{schema}".device_authorizations (device_code_hash);
          -- Only `pending` rows need a unique user_code; approved/consumed
          -- rows may share codes from past flows without collision.
          CREATE UNIQUE INDEX IF NOT EXISTS idx_device_authorizations_user_code_pending
            ON "#{schema}".device_authorizations (user_code_hash)
            WHERE status = 'pending';
          CREATE INDEX IF NOT EXISTS idx_device_authorizations_expiry
            ON "#{schema}".device_authorizations (expires_at)
            WHERE status IN ('pending', 'approved');
        DDL
      end

      # 005: the AP2 trail. `id` is server-generated; `reference` is the hash of
      # the presented SD-JWT, unique per principal. One checkout holds one live
      # checkout mandate: `declined_at` records a charge refused with no money
      # moved, and frees the checkout. A settlement is server-minted.
      def mandates_sql(schema: nil, user_id_type: nil)
        schema       ||= Kiosk.configuration.schema
        user_id_type ||= Kiosk.configuration.user_id_type
        col_type = user_id_cast(user_id_type)

        <<~DDL.strip
          CREATE TABLE IF NOT EXISTS "#{schema}".checkout_mandates (
            id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            reference          text NOT NULL,
            checkout_hash      text NOT NULL,
            user_id            #{col_type} NOT NULL,
            agent_id           uuid NOT NULL,
            issuer             text NOT NULL,
            line_items         jsonb NOT NULL,
            total_amount_cents bigint NOT NULL,
            currency           text NOT NULL,
            expires_at         timestamptz NOT NULL,
            created_at         timestamptz NOT NULL DEFAULT now(),
            sd_jwt             text NOT NULL,
            declined_at        timestamptz,
            UNIQUE (user_id, reference)
          );
          CREATE INDEX IF NOT EXISTS idx_checkout_mandates_user_id ON "#{schema}".checkout_mandates (user_id);
          CREATE UNIQUE INDEX IF NOT EXISTS idx_checkout_mandates_live_checkout
            ON "#{schema}".checkout_mandates (user_id, checkout_hash) WHERE declined_at IS NULL;

          CREATE TABLE IF NOT EXISTS "#{schema}".payment_mandates (
            id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            reference           text NOT NULL,
            checkout_mandate_id uuid NOT NULL REFERENCES "#{schema}".checkout_mandates(id) ON DELETE CASCADE,
            user_id             #{col_type} NOT NULL,
            agent_id            uuid NOT NULL,
            issuer              text NOT NULL,
            payment_instrument  text NOT NULL,
            amount_cents        bigint NOT NULL,
            currency            text NOT NULL,
            expires_at          timestamptz,
            created_at          timestamptz NOT NULL DEFAULT now(),
            sd_jwt              text NOT NULL,
            UNIQUE (user_id, reference)
          );
          CREATE INDEX IF NOT EXISTS idx_payment_mandates_user_id  ON "#{schema}".payment_mandates (user_id);
          CREATE INDEX IF NOT EXISTS idx_payment_mandates_checkout ON "#{schema}".payment_mandates (checkout_mandate_id);

          CREATE TABLE IF NOT EXISTS "#{schema}".settlements (
            id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            checkout_mandate_id  uuid NOT NULL REFERENCES "#{schema}".checkout_mandates(id) ON DELETE CASCADE,
            user_id              #{col_type} NOT NULL,
            agent_id             uuid NOT NULL,
            issuer               text NOT NULL,
            psp_reference        text NOT NULL,
            settled_amount_cents bigint NOT NULL,
            currency             text NOT NULL,
            network_confirmation_id text,
            settled_at           timestamptz NOT NULL,
            UNIQUE (checkout_mandate_id)
          );
          CREATE INDEX IF NOT EXISTS idx_settlements_user_id  ON "#{schema}".settlements (user_id);
          CREATE INDEX IF NOT EXISTS idx_settlements_checkout ON "#{schema}".settlements (checkout_mandate_id);
        DDL
      end

      # 006: KYC grants and open verifications, keyed on the person.
      def kyc_attributes_sql(schema: nil, user_id_type: nil, user_table: nil)
        schema       ||= Kiosk.configuration.schema
        user_id_type ||= Kiosk.configuration.user_id_type
        user_table   ||= configured_user_table
        col_type = user_id_cast(user_id_type)
        person   = %(#{col_type} NOT NULL REFERENCES "#{user_table}"(id) ON DELETE CASCADE)

        <<~DDL.strip
          CREATE TABLE IF NOT EXISTS "#{schema}".kyc_attributes (
            user_id    #{person},
            name       text NOT NULL,
            granted_at timestamptz NOT NULL DEFAULT now(),
            PRIMARY KEY (user_id, name)
          );

          CREATE TABLE IF NOT EXISTS "#{schema}".kyc_requests (
            id          text PRIMARY KEY,
            user_id     #{person},
            nonce       text NOT NULL,
            approved_at timestamptz,
            created_at  timestamptz NOT NULL DEFAULT now()
          );
          CREATE INDEX IF NOT EXISTS idx_kyc_requests_user_id ON "#{schema}".kyc_requests (user_id, created_at);
        DDL
      end

      # 007: the event tail; `id` is the origin's one monotonic cursor.
      def events_sql(schema: nil)
        schema ||= Kiosk.configuration.schema

        <<~DDL.strip
          CREATE TABLE IF NOT EXISTS "#{schema}".events (
            id           bigserial   PRIMARY KEY,
            identity_key text        NOT NULL,
            topic        text        NOT NULL,
            subject      text,
            occurred_at  timestamptz NOT NULL,
            data         jsonb       NOT NULL,
            created_at   timestamptz NOT NULL DEFAULT now()
          );
          -- `since` for one subscriber: the cursor scan, in id order.
          CREATE INDEX IF NOT EXISTS idx_events_identity_key_id
            ON "#{schema}".events (identity_key, id);
          -- The retention sweep only.
          CREATE INDEX IF NOT EXISTS idx_events_created_at
            ON "#{schema}".events (created_at);
        DDL
      end

      # 008: spent proof-of-work challenge ids; the primary key is the single-use gate.
      def pow_spent_sql(schema: nil)
        schema ||= Kiosk.configuration.schema

        <<~DDL.strip
          CREATE TABLE IF NOT EXISTS "#{schema}".pow_spent (
            id         text        PRIMARY KEY,
            expires_at timestamptz NOT NULL
          );
          -- Supports the TTL sweep only; the PK above is what enforces
          -- single-use.
          CREATE INDEX IF NOT EXISTS idx_pow_spent_expires_at
            ON "#{schema}".pow_spent (expires_at);
        DDL
      end

      # 009: each agent's revocation watermark: a token issued before it stops verifying.
      def revocations_sql(schema: nil)
        schema ||= Kiosk.configuration.schema

        <<~DDL.strip
          CREATE TABLE IF NOT EXISTS "#{schema}".revocations (
            agent_id       uuid        PRIMARY KEY REFERENCES "#{schema}".agents(id) ON DELETE CASCADE,
            revoked_before timestamptz NOT NULL
          );
        DDL
      end

      # 011: the visits an operator records as fulfilled; reputation counts their value.
      def visits_sql(schema: nil, user_id_type: nil)
        schema ||= Kiosk.configuration.schema
        col_type = user_id_cast(user_id_type || Kiosk.configuration.user_id_type)

        <<~DDL.strip
          CREATE TABLE IF NOT EXISTS "#{schema}".visits (
            id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            user_id     #{col_type} NOT NULL,
            value_cents bigint NOT NULL CHECK (value_cents >= 0),
            visited_at  timestamptz NOT NULL DEFAULT now()
          );
          CREATE INDEX IF NOT EXISTS idx_visits_user_id ON "#{schema}".visits (user_id, visited_at);
        DDL
      end

      # 012: the refunds of settled charges, one row per PSP refund; recent
      # spend counts a settlement less what was refunded of it.
      def refunds_sql(schema: nil)
        schema ||= Kiosk.configuration.schema

        <<~DDL.strip
          CREATE TABLE IF NOT EXISTS "#{schema}".refunds (
            id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            settlement_id         uuid NOT NULL REFERENCES "#{schema}".settlements(id) ON DELETE CASCADE,
            psp_reference         text NOT NULL UNIQUE,
            refunded_amount_cents bigint NOT NULL CHECK (refunded_amount_cents > 0),
            refunded_at           timestamptz NOT NULL
          );
          CREATE INDEX IF NOT EXISTS idx_refunds_settlement_id ON "#{schema}".refunds (settlement_id);
        DDL
      end

      # 010: each public key's outstanding auth challenge; the primary key keeps it single.
      def auth_challenge_sql(schema: nil)
        schema ||= Kiosk.configuration.schema

        <<~DDL.strip
          CREATE TABLE IF NOT EXISTS "#{schema}".auth_challenges (
            public_key text        PRIMARY KEY,
            nonce      text        NOT NULL,
            expires_at timestamptz NOT NULL
          );
          -- Supports the TTL sweep only.
          CREATE INDEX IF NOT EXISTS idx_auth_challenges_expires_at
            ON "#{schema}".auth_challenges (expires_at);
        DDL
      end

      def configured_user_table = Kiosk.configuration.user_model.to_s.constantize.table_name

      def user_id_cast(user_id_type)
        case user_id_type.to_sym
        when :uuid               then 'uuid'
        when :bigint, :integer   then user_id_type.to_s
        when :text               then 'text'
        else
          raise ArgumentError,
                "user_id_type must be one of :uuid, :bigint, :integer, :text — got #{user_id_type.inspect}"
        end
      end
    end
  end
end
