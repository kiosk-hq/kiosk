# frozen_string_literal: true

require "kiosk/server/version"

module Kiosk
  module Server
    # The SQL of the migrations `kiosk:install` emits, one method per
    # migration, each creating its tables in their final shape. No database
    # connection; the host's migrations `execute` it.
    module SchemaDefinitions
      module_function

      # 001: the schema and the `current_*()` GUC readers.
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

      # 002: `agents` (`spending_cap_cents`: NULL unlimited, 0 disabled),
      # `agent_tokens`, `agent_mappings`.
      def identity_tables_sql(schema: nil, user_id_type: nil, user_table: "users")
        schema      ||= Kiosk.configuration.schema
        user_id_type ||= Kiosk.configuration.user_id_type
        col_type = user_id_cast(user_id_type)

        <<~SQL.strip
          CREATE TABLE IF NOT EXISTS "#{schema}".agents (
            id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            user_id             #{col_type} NOT NULL REFERENCES "#{user_table}"(id) ON DELETE CASCADE,
            allowed_roles       text[] NOT NULL DEFAULT '{}'::text[],
            public_key          text,
            human_label         text,
            spending_cap_cents  bigint,
            created_at          timestamptz NOT NULL DEFAULT now(),
            revoked_at          timestamptz,
            issuer              text NOT NULL
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
        SQL
      end

      # 003: TTL rows holding inventory while the mandate chain completes.
      def reservations_sql(schema: nil, user_id_type: nil)
        schema      ||= Kiosk.configuration.schema
        user_id_type ||= Kiosk.configuration.user_id_type
        col_type = user_id_cast(user_id_type)

        <<~SQL.strip
          CREATE TABLE IF NOT EXISTS "#{schema}".reservations (
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
          CREATE INDEX IF NOT EXISTS idx_reservations_user_id  ON "#{schema}".reservations (user_id);
          CREATE INDEX IF NOT EXISTS idx_reservations_expiry   ON "#{schema}".reservations (expires_at) WHERE released_at IS NULL;
        SQL
      end

      # 004: account-binding requests; codes are stored hashed only.
      # `requested_role` is the approving human's role, never a client's.
      def device_authorizations_sql(schema: nil, user_id_type: nil)
        schema      ||= Kiosk.configuration.schema
        user_id_type ||= Kiosk.configuration.user_id_type
        col_type = user_id_cast(user_id_type)

        <<~SQL.strip
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
        SQL
      end

      # 005: the AP2 trail. `id` is server-generated; the signed mandate id is
      # `mandate_id`, unique per principal. A settlement is server-minted, so it
      # carries no `raw_jws`.
      def mandates_sql(schema: nil, user_id_type: nil)
        schema       ||= Kiosk.configuration.schema
        user_id_type ||= Kiosk.configuration.user_id_type
        col_type = user_id_cast(user_id_type)

        <<~SQL.strip
          CREATE TABLE IF NOT EXISTS "#{schema}".intent_mandates (
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
          CREATE INDEX IF NOT EXISTS idx_intent_mandates_user_id  ON "#{schema}".intent_mandates (user_id);
          CREATE INDEX IF NOT EXISTS idx_intent_mandates_agent_id ON "#{schema}".intent_mandates (agent_id);

          CREATE TABLE IF NOT EXISTS "#{schema}".cart_mandates (
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
          CREATE INDEX IF NOT EXISTS idx_cart_mandates_user_id ON "#{schema}".cart_mandates (user_id);
          CREATE INDEX IF NOT EXISTS idx_cart_mandates_intent  ON "#{schema}".cart_mandates (intent_mandate_id);

          CREATE TABLE IF NOT EXISTS "#{schema}".payment_mandates (
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
          CREATE INDEX IF NOT EXISTS idx_payment_mandates_user_id ON "#{schema}".payment_mandates (user_id);
          CREATE INDEX IF NOT EXISTS idx_payment_mandates_cart    ON "#{schema}".payment_mandates (cart_mandate_id);

          CREATE TABLE IF NOT EXISTS "#{schema}".settlements (
            id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            cart_mandate_id      uuid NOT NULL REFERENCES "#{schema}".cart_mandates(id) ON DELETE CASCADE,
            user_id              #{col_type} NOT NULL,
            agent_id             uuid NOT NULL,
            issuer               text NOT NULL,
            psp_reference        text NOT NULL,
            settled_amount_cents bigint NOT NULL,
            currency             text NOT NULL,
            settled_at           timestamptz NOT NULL,
            UNIQUE (cart_mandate_id)
          );
          CREATE INDEX IF NOT EXISTS idx_settlements_user_id ON "#{schema}".settlements (user_id);
          CREATE INDEX IF NOT EXISTS idx_settlements_cart    ON "#{schema}".settlements (cart_mandate_id);
        SQL
      end

      # 006: KYC grants and open verifications, keyed on the person.
      def kyc_attributes_sql(schema: nil, user_id_type: nil, user_table: nil)
        schema       ||= Kiosk.configuration.schema
        user_id_type ||= Kiosk.configuration.user_id_type
        user_table   ||= configured_user_table
        col_type = user_id_cast(user_id_type)
        person   = %(#{col_type} NOT NULL REFERENCES "#{user_table}"(id) ON DELETE CASCADE)

        <<~SQL.strip
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
        SQL
      end

      # 007: the event tail; `id` is the origin's one monotonic cursor.
      def events_sql(schema: nil)
        schema ||= Kiosk.configuration.schema

        <<~SQL.strip
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
        SQL
      end

      # 008: spent proof-of-work challenge ids; the primary key is the single-use gate.
      def pow_spent_sql(schema: nil)
        schema ||= Kiosk.configuration.schema

        <<~SQL.strip
          CREATE TABLE IF NOT EXISTS "#{schema}".pow_spent (
            id         text        PRIMARY KEY,
            expires_at timestamptz NOT NULL
          );
          -- Supports the TTL sweep only; the PK above is what enforces
          -- single-use.
          CREATE INDEX IF NOT EXISTS idx_pow_spent_expires_at
            ON "#{schema}".pow_spent (expires_at);
        SQL
      end

      # Not in the canonical set: the shared auth-challenge table a multi-process
      # operator adds. At most one outstanding challenge per key.
      def auth_challenge_sql(schema: nil)
        schema ||= Kiosk.configuration.schema

        <<~SQL.strip
          CREATE TABLE IF NOT EXISTS "#{schema}".auth_challenges (
            public_key text        PRIMARY KEY,
            nonce      text        NOT NULL,
            expires_at timestamptz NOT NULL
          );
          -- Supports the TTL sweep only; the PK above is what makes a key's
          -- outstanding challenge single.
          CREATE INDEX IF NOT EXISTS idx_auth_challenges_expires_at
            ON "#{schema}".auth_challenges (expires_at);
        SQL
      end

      def configured_user_table = Kiosk.configuration.user_model.to_s.constantize.table_name

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
