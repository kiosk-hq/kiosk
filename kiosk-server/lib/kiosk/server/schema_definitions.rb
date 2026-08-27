# frozen_string_literal: true

module Kiosk
  module Server
    # Pure SQL generators for the six canonical Kiosk migrations.
    #
    #   001 create_kiosk_schema                → schema + four current_*() helpers
    #   002 create_kiosk_identity_tables       → agents, agent_tokens, agent_mappings
    #   003 create_kiosk_reservations          → kiosk.reservations
    #   004 create_kiosk_device_authorizations → kiosk.device_authorizations (account binding)
    #   005 create_kiosk_mandates              → intent_mandates, cart_mandates, payment_mandates, settlements (AP2 trail)
    #   006 create_kiosk_kyc_attributes        → kiosk.kyc_attributes, one row per
    #       named anonymized boolean an attestation granted an agent
    #
    # REBUILT FROM SCRATCH AND RENUMBERED 2026-08-20 (K-646, Phil: «Поменяй
    # шаблон генерации миграций и сделай миграции начисто в демо. прод базы
    # можно дропнуть»). The set that shipped until then carried its own
    # history: ten ordinals of which one was retired, a `create` for
    # device_authorizations whose table migration 008 immediately DROPPED and
    # rebuilt, and three `add_*_to_kiosk_agents` migrations amending columns
    # onto a table two migrations earlier. A fresh adopter ran ten files to
    # reach a schema that six files state outright. There are no adopters, and the
    # databases on both sides are dropped, so keeping the amendments preserves
    # nothing — each is folded into the `create` it amended:
    #
    #   old 007 add_kyc_verified_at            → a column in 002's agents table
    #   old 010 add_kiosk_agent_governance_columns → two columns in 002's agents table
    #   old 008 rebuild_device_authorizations  → 004 creates the final shape
    #   old 003 create_kiosk_actions_log       → retired 2026-08-20 (K-828); the
    #       audit trail is the operator's now (`c.audit_sink`) and Kiosk stores
    #       none of it, so there is no slot to keep
    #   old 009 add_kyc_attributes             → 006, which creates a table
    #       rather than adding a jsonb column (K-656)
    #
    # RENUMBERING WAS MEASURED, NOT ASSUMED. The rule that kept 004-010 frozen
    # when 003 retired was "those numbers are named in shipped comments and
    # CHANGELOG history". Counted at the rewrite: EIGHT live references to an
    # old ordinal existed outside the artifacts this change rewrites anyway
    # (device_authorization_stores.rb ×2 and its spec, configuration_extension.rb,
    # server.rb, audit_sink.rb, ADR-0019 ×2 — two of which were ALREADY stale,
    # naming 009 for columns that became 010). Eight is a sweep, not a project,
    # so they were swept. CHANGELOG entries keep their old numbers on purpose:
    # they are dated statements about what shipped then, not claims about now.
    #
    # EVERY `CREATE` HERE IS GUARDED WITH `IF NOT EXISTS`, AND THE RENUMBERING
    # ABOVE IS WHY (K-1083, MEASURED 2026-08-27). Renumbering a migration is
    # invisible from zero and fatal on a running deployment: the deleted
    # versions are the ones a pre-2026-08-20 database carries in
    # `schema_migrations`, so all six re-emitted files read as PENDING there and
    # `db:migrate` replays them onto tables that already exist. Reproduced
    # exactly — load the tudu `db/structure.sql` of `267e67b3^`, run `db:migrate`
    # at head, and it aborts ONE STEP IN at
    # `20260820130113_create_kiosk_identity_tables` with `PG::DuplicateTable:
    # relation "agents" already exists`, having already recorded
    # `20260820130112` (001 was idempotent, 002 was not). Every later migration
    # on that box is then unreachable — including any corrective one.
    #
    # A guarded `CREATE` buys that at a price the ledger names: it ACCEPTS an
    # existing table instead of failing loudly, so a table that has DRIFTED from
    # what this file states passes silently. Two things pay for it, and neither
    # is optional. First, guarded creates are paired with idempotent repairs
    # wherever a fold moved a column (see {.identity_tables_sql}) — the guard
    # skips, but the repair still runs. Second, `bin/check-migration-replay`
    # runs the whole replay in CI on every push and diffs the resulting catalog
    # against the tracked `db/structure.sql`, so drift is not silent: it is a
    # red build naming the missing object, BEFORE a deploy, rather than an
    # HTTP 500 on a box afterwards. The loud failure did not go away; it moved
    # earlier. Do not remove one of those two halves without the other.
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
      #
      # `agents` carries three columns that until 2026-08-20 arrived as three
      # separate later migrations amending this table (K-646). They are
      # nullable and cost an operator who never uses them nothing, and a
      # provider who DOES enable the surface reading them should not have to
      # discover that the column is in a migration they were told was optional:
      #
      #   kyc_verified_at    — non-NULL once the agent has submitted a valid
      #                        KYC attestation; the binary KYC gate
      #                        ({DefaultAgentIdp#kyc_verified?}). The NAMED
      #                        attributes live in their own table (006).
      #   spending_cap_cents — per-assistant spend cap; NULL = unlimited (the
      #                        default), 0 = disabled. Enforced by the pay path
      #                        via the `config.spending_cap` seam
      #                        ({ColumnSpendingCap} reads this column).
      #   human_label        — a human-friendly name for the manage-assistants
      #                        page.
      #
      # THE THREE `ADD COLUMN IF NOT EXISTS` LINES BELOW ARE THE OTHER HALF OF
      # THAT FOLD, AND THEY ARE NOT DECORATION (K-1083). Folding three amendment
      # migrations into this `CREATE` is only lossless for a database built FROM
      # ZERO. A database that ran the pre-2026-08-20 set already has an `agents`
      # table — built by the old 002 — and reaches this migration with whichever
      # subset of the three columns its vintage had amended on. MEASURED on the
      # structure.sql the reference fleet's boxes were built from: `human_label`
      # and `spending_cap_cents` present, `kyc_verified_at` ABSENT. A guarded
      # `CREATE` alone would step over that table and record itself as applied,
      # leaving the column the binary KYC gate SELECTs permanently missing — the
      # K-436 / K-1074 failure exactly. So 002 does not merely skip a table it
      # finds; it brings it up to the shape this file states.
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
            notification_pubkey text,
            human_label         text,
            spending_cap_cents  bigint,
            kyc_verified_at     timestamptz,
            created_at          timestamptz NOT NULL DEFAULT now(),
            revoked_at          timestamptz
          );
          -- Brings a pre-K-646 `agents` table up to the shape above: these are
          -- exactly the three columns that used to arrive as separate amending
          -- migrations, so a database of that vintage has some, all or none of
          -- them. No-ops on the FROM-ZERO path — the CREATE above already made
          -- them, so `db/structure.sql` is unchanged either way.
          ALTER TABLE "#{schema}".agents ADD COLUMN IF NOT EXISTS human_label        text;
          ALTER TABLE "#{schema}".agents ADD COLUMN IF NOT EXISTS spending_cap_cents bigint;
          ALTER TABLE "#{schema}".agents ADD COLUMN IF NOT EXISTS kyc_verified_at    timestamptz;

          CREATE INDEX IF NOT EXISTS idx_agents_user_id ON "#{schema}".agents (user_id) WHERE revoked_at IS NULL;
          -- Dedupe at the DB, not via SELECT-then-INSERT (TOCTOU): two LIVE
          -- rows for one public key cannot coexist. Partial (WHERE revoked_at
          -- IS NULL) so a revoked key can re-register.
          CREATE UNIQUE INDEX IF NOT EXISTS idx_agents_public_key_live
            ON "#{schema}".agents (public_key) WHERE revoked_at IS NULL;

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

      # ─── 003 create_kiosk_reservations ─────────────────────────────────

      # Atomic reserve-then-pay primitive. TTL row in `kiosk.reservations`
      # holds inventory while AP2 mandate trail completes; expiry releases
      # automatically.
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

      # ─── 004 create_kiosk_device_authorizations ────────────────────────

      # The account-binding state machine table: one row per
      # device-authorization / link request — created on
      # /oauth/device_authorization (or the human-initiated link page), mutated
      # by /oauth/device/verify (approve/deny), consumed by /oauth/token
      # (device_code grant). Read and written by
      # {DeviceAuthorizationStores::ActiveRecord}, the durable store.
      #
      #   - `user_code_hash` — the human-displayable short code (8 chars from
      #     the 31-char read-aloud-unambiguous alphabet, XXXX-XXXX) is stored
      #     HASHED ONLY (SHA-256 hex, matching `agent_tokens.token_hash`); the
      #     plaintext lives only in the response to the initiating client and
      #     on the verify page.
      #   - `device_code_hash` — SHA-256 hex of the actual device_code, which is
      #     likewise never persisted.
      #   - `public_key_pem` — the key the ceremony binds (BIND-POP proves
      #     possession of it before any binding).
      #   - `kind` — `claim` (agent-initiated) or `link` (human-initiated, rows
      #     born pre-approved and already bound to the human).
      #   - `requested_role` — A MISNOMER, and kept on purpose (K-1126).
      #     Nothing requests it: on a `claim` row it is written at APPROVAL
      #     from the approving human's `Identity#role`, on a `link` row at MINT
      #     from the minting human's own — never by a client, which since K-072
      #     is refused outright for naming a role. Read it as `approved_role`.
      #     The spelling stays because ADR-0011 states its invariant under this
      #     name and because renaming a shipped column means a new migration in
      #     each of the seven demo `db/structure.sql` files plus a
      #     `bin/check-migration-replay` pass — a migration wave for a word.
      #
      # Until 2026-08-20 this arrived in two migrations: an 0.1 shape nothing
      # ever wrote, and a `rebuild` that DROPPED and recreated it in this one
      # (K-646 folded them; there was no data either could have carried).
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

      # ─── 005 create_kiosk_mandates ─────────────────────────────────────

      # AP2 mandate trail: three signed mandate tables — `intent_mandates`
      # (spending envelope signed by the user), `cart_mandates`
      # (agent-assembled cart within the envelope), `payment_mandates`
      # (assistant-signed payment mandate carrying the payment instrument) —
      # plus `settlements` (PSP settlement receipt). Each signed-mandate row
      # carries its original JWS so the chain is auditable end-to-end.
      #
      # A SETTLEMENT HAS NO `raw_jws`, AND THAT IS THE POINT (K-948). The three
      # mandate tables each hold one — the assistant signed those, and §11.6's
      # replay check compares all three byte for byte — but a settlement is a
      # SERVER-MINTED receipt: nobody signs it, so there is no signature to
      # store. It shipped until 2026-08-23 as a `text NOT NULL` column that its
      # only writer set to `''` on every row, which read like the sibling
      # tables' load-bearing column and was exactly the misreading K-876 found
      # published («non-repudiation both ways»). An operator counter-signature
      # would be a new normative protocol element — an ADR, not a column — so
      # the column goes rather than waiting for a producer. ADR-0002 has said
      # `settlements` has «no `mandate_id` and no `raw_jws`» since the table
      # was named; this makes the schema agree with it.
      #
      # REMOVING IT FROM THIS `CREATE` WAS ONLY HALF THE CHANGE (K-1086). This
      # DDL reaches a database that is built FROM ZERO; a database built while
      # the old CREATE was head still carries `raw_jws text NOT NULL` with no
      # DEFAULT, head's INSERT does not name it, and Postgres refuses every
      # settlement INSERT there — permanently, because nothing in this file can
      # take a column away from a table that already exists. The drop ships as
      # its own migration,
      # `db/migrate/20260827000002_drop_kiosk_settlement_raw_jws.rb`, in each of
      # the seven demos that hold this table. THE RULE IS SYMMETRICAL: a column
      # REMOVED from this file needs a shipped `DROP` for exactly the reason a
      # column ADDED needs a shipped `ADD` (T-103 clause (vii); K-1074 is the
      # additive half of the same delivery gap, and only that half had ever been
      # written down). `bin/check-migration-replay` is what says it out loud.
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

      # ─── 006 create_kiosk_kyc_attributes ───────────────────────────────

      # `kyc_attributes` — ONE ROW per NAMED ANONYMIZED boolean a valid KYC
      # attestation granted an agent (`age_over_18`, `licence_a`, ...). Only
      # the NAMES are stored — never the DOB, licence number, or any underlying
      # document, which is the anonymized property ADR-0020 exists for.
      #
      # A TABLE, not the `agents.kyc_attributes jsonb` column that shipped
      # until 2026-08-20 as migration 009 (decision KYC-ATTRIBUTES-TABLE,
      # Phil 2026-08-12; K-656/T-061).
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
          CREATE TABLE IF NOT EXISTS "#{schema}".kyc_attributes (
            agent_id   uuid NOT NULL REFERENCES "#{schema}".agents(id) ON DELETE CASCADE,
            name       text NOT NULL,
            granted_at timestamptz NOT NULL DEFAULT now(),
            PRIMARY KEY (agent_id, name)
          );
        SQL
      end

      # ─── optional: shared PoW spent-id table (NOT a canonical migration) ─

      # Table backing {PowSpentStores::ActiveRecord}, the shared spent-id
      # store a MULTI-PROCESS operator must configure so that PoW single-use
      # holds across web workers (K-738).
      #
      # This is deliberately NOT one of the six canonical migrations and the
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

      # The SHARED auth-challenge table for multi-process operators (K-751) —
      # the sibling of {.pow_spent_sql}, and not part of the canonical
      # migration set for the same reason: a single-process operator does not
      # need it. See the kiosk-server README, "Multi-process deployments".
      #
      # `public_key` is the registering/logging-in PEM and it is the PRIMARY
      # KEY, because the store's contract is "at most one outstanding challenge
      # per key" — re-issuing overwrites, which the key plus
      # `ON CONFLICT DO UPDATE` states in ONE statement. `expires_at` mirrors
      # the challenge TTL; every read carries `expires_at > now()`, so an
      # expired row can never be taken and the index below serves only
      # {AuthChallengeStores::ActiveRecord#prune!}.
      #
      # NOTE the failure direction, because it is the opposite of `pow_spent`:
      # an unshared challenge store cannot FIND a nonce another worker issued,
      # so the handshake fails CLOSED (a rejected, correctly-signed request)
      # rather than accepting something it should not.
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
