# frozen_string_literal: true

RSpec.describe Kiosk::Server::SchemaDefinitions do
  describe ".helper_functions_sql" do
    subject(:sql) { described_class.helper_functions_sql }

    it "creates the schema (idempotent)" do
      expect(sql).to include(%(CREATE SCHEMA IF NOT EXISTS "kiosk"))
    end

    it "defines all four current_*() helpers" do
      %w[current_user_id current_role current_actor current_agent_id].each do |fn|
        expect(sql).to include(%(FUNCTION "kiosk".#{fn}()))
      end
    end

    it "marks the helpers as STABLE" do
      expect(sql.scan(/LANGUAGE sql STABLE/).size).to eq(4)
    end

    it "types current_user_id() against the configured user-id type (default :uuid)" do
      expect(sql).to include("current_user_id() RETURNS uuid")
      expect(sql).to include("::uuid")
    end

    it "types current_user_id() against :bigint when configured" do
      Kiosk.configure { |c| c.user_id_type = :bigint }
      out = described_class.helper_functions_sql
      expect(out).to include("current_user_id() RETURNS bigint")
      expect(out).to include("::bigint")
    end

    it "uses the configured GUC namespace (default 'app')" do
      expect(sql).to include("current_setting('app.current_user_id', true)")
    end

    it "uses an overridden GUC namespace" do
      Kiosk.configure { |c| c.guc_namespace = "kiosk-all" }
      out = described_class.helper_functions_sql
      expect(out).to include("current_setting('kiosk-all.current_user_id', true)")
    end

    it "uses an overridden schema name" do
      Kiosk.configure { |c| c.schema = "ksk" }
      out = described_class.helper_functions_sql
      expect(out).to include(%(CREATE SCHEMA IF NOT EXISTS "ksk"))
      expect(out).to include(%(FUNCTION "ksk".current_user_id()))
    end

    it "allows explicit overrides regardless of Kiosk.configuration" do
      out = described_class.helper_functions_sql(schema: "x", guc_namespace: "y", user_id_type: :text)
      expect(out).to include(%(CREATE SCHEMA IF NOT EXISTS "x"))
      expect(out).to include("current_setting('y.current_user_id', true)")
      expect(out).to include("current_user_id() RETURNS text")
    end
  end

  describe ".identity_tables_sql" do
    subject(:sql) { described_class.identity_tables_sql }

    it "creates `agents` with NOT NULL user_id FK to the configured user table" do
      expect(sql).to include(%(CREATE TABLE "kiosk".agents))
      expect(sql).to include("user_id             uuid NOT NULL REFERENCES \"users\"(id)")
    end

    it "creates `agent_tokens` with FK to agents and a unique token_hash" do
      expect(sql).to include(%(CREATE TABLE "kiosk".agent_tokens))
      expect(sql).to include(%(REFERENCES "kiosk".agents(id) ON DELETE CASCADE))
      expect(sql).to include(%(UNIQUE INDEX idx_agent_tokens_hash))
    end

    it "creates `agent_mappings` for external-IdP subject ↔ local agent linkage" do
      expect(sql).to include(%(CREATE TABLE "kiosk".agent_mappings))
      expect(sql).to include("PRIMARY KEY (provider, external_id)")
    end

    it "uses the configured user_table name" do
      out = described_class.identity_tables_sql(user_table: "members")
      expect(out).to include(%(REFERENCES "members"(id)))
    end

    it "types user_id column against :bigint when configured" do
      Kiosk.configure { |c| c.user_id_type = :bigint }
      out = described_class.identity_tables_sql
      expect(out).to include("user_id             bigint NOT NULL")
    end

    # DB-level dedupe of the credential, not TOCTOU SELECT-then-INSERT.
    it "adds a PARTIAL unique index on public_key for LIVE (non-revoked) rows only" do
      expect(sql).to match(
        /CREATE UNIQUE INDEX idx_agents_public_key_live\s+ON "kiosk"\.agents \(public_key\) WHERE revoked_at IS NULL/,
      )
    end

    it "keeps the public_key uniqueness partial so a revoked key can re-register" do
      # A bare (non-partial) UNIQUE on public_key would block re-registering a
      # revoked key — the index MUST be scoped to revoked_at IS NULL.
      expect(sql).not_to match(/UNIQUE INDEX idx_agents_public_key_live\s+ON "kiosk"\.agents \(public_key\);/)
    end

    # Folded in from the three later migrations that used to ALTER them onto
    # this table (K-646): nullable, free to an operator who never uses them,
    # and a provider enabling the surface that reads one should not have to
    # discover it lives in a migration they were told was optional.
    it "declares kyc_verified_at, spending_cap_cents and human_label on agents" do
      agents = sql[/CREATE TABLE "kiosk"\.agents.*?\);/m]
      expect(agents).to include("kyc_verified_at     timestamptz")
      expect(agents).to include("spending_cap_cents  bigint")
      expect(agents).to include("human_label         text")
    end

    it "emits no ALTER TABLE at all — the create states the whole table" do
      expect(sql).not_to include("ALTER TABLE")
      expect(sql).not_to include("ADD COLUMN")
    end
  end

  # The actions-log generator is GONE (K-828, 2026-08-20): Kiosk stores no
  # audit trail at all — it emits one ActionEvent per invocation to the
  # operator's `audit_sink`. K-646 then rebuilt the canonical set from scratch,
  # so it does not even leave a retired ordinal behind.
  describe "the retired actions-log generator" do
    it "no longer exists" do
      expect(described_class).not_to respond_to(:actions_log_sql)
    end

    # The three amendment generators K-646 folded away. They are gone rather
    # than deprecated — a shim would be a second way to build the same schema,
    # which is precisely the divergence this rebuild exists to end.
    it "leaves no amendment generator behind either" do
      expect(described_class).not_to respond_to(:kyc_verified_at_sql)
      expect(described_class).not_to respond_to(:agent_governance_columns_sql)
      expect(described_class).not_to respond_to(:rebuild_device_authorizations_sql)
    end

    it "is emitted by no other canonical generator" do
      sql = [described_class.helper_functions_sql, described_class.identity_tables_sql,
             described_class.reservations_sql, described_class.device_authorizations_sql,
             described_class.mandates_sql].join("\n")
      expect(sql).not_to include("action_log")
      expect(sql).not_to include(%(CREATE TABLE "kiosk".actions))
    end
  end

  describe ".reservations_sql" do
    subject(:sql) { described_class.reservations_sql }

    it "creates `kiosk.reservations` with TTL fields for atomic reserve-then-pay" do
      expect(sql).to include(%(CREATE TABLE "kiosk".reservations))
      expect(sql).to include("expires_at    timestamptz NOT NULL")
      expect(sql).to include("released_at   timestamptz")
    end

    it "indexes active reservations by expiry for cleanup sweeps" do
      expect(sql).to include("WHERE released_at IS NULL")
    end
  end

  describe ".mandates_sql" do
    subject(:sql) { described_class.mandates_sql(schema: "kiosk", user_id_type: :uuid) }

    it "creates the three signed mandate tables and the settlements receipt table" do
      expect(sql).to include('CREATE TABLE "kiosk".intent_mandates')
      expect(sql).to include('CREATE TABLE "kiosk".cart_mandates')
      expect(sql).to include('CREATE TABLE "kiosk".payment_mandates')
      expect(sql).to include('CREATE TABLE "kiosk".settlements')
    end

    it "links cart→intent, payment→cart, and settlement→cart by FK" do
      expect(sql).to include('REFERENCES "kiosk".intent_mandates(id)')
      expect(sql).to include('REFERENCES "kiosk".cart_mandates(id)')
    end

    it "stores money as bigint cents and keeps raw JWS" do
      expect(sql).to include("cap_amount_cents  bigint")
      expect(sql).to include("settled_amount_cents bigint")
      expect(sql.scan("raw_jws").size).to eq(3)
    end

    # K-948. The three SIGNED mandate tables each carry the JWS the assistant
    # signed; a settlement is a server-minted receipt nobody signs, so a
    # `raw_jws` column on it could only ever hold the empty string its one
    # writer put there. `eq(3)` above and this assertion are the same fact read
    # from both ends: exactly three, and not on this table.
    it "gives settlements NO raw_jws column — nobody signs a server-minted receipt" do
      settlements_table = sql[/CREATE TABLE "kiosk"\.settlements.*?\);/m]
      expect(settlements_table).not_to match(/^\s*raw_jws\s+\w/)
    end

    it "keeps a server-generated uuid PK on every table (never caller-supplied)" do
      expect(sql.scan(/\bid +uuid PRIMARY KEY DEFAULT gen_random_uuid\(\)/).size).to eq(4)
    end

    it "stores the agent-signed mandate id in a mandate_id text NOT NULL column on all three signed mandates" do
      # intent, cart, and payment_mandates are all agent-signed and carry a signed id;
      # settlements is a server-side PSP receipt with no agent-signed mandate_id.
      expect(sql.scan(/mandate_id +text NOT NULL/).size).to eq(3)
      settlements_table = sql[/CREATE TABLE "kiosk"\.settlements.*?\);/m]
      # No standalone `mandate_id <type>` column on settlements.
      expect(settlements_table).not_to match(/^\s*mandate_id\s+\w/)
    end

    it "enforces per-principal uniqueness of the signed id on all three signed mandates" do
      expect(sql).to include("UNIQUE (user_id, mandate_id)")
      # one for intent_mandates, one for cart_mandates, one for payment_mandates
      expect(sql.scan("UNIQUE (user_id, mandate_id)").size).to eq(3)
    end

    it "anchors idempotency with one settlement per cart on settlements" do
      expect(sql).to include("UNIQUE (cart_mandate_id)")
    end

    it "the signed payment_mandates table carries mandate_id, payment_method, amount_cents, and UNIQUE(user_id, mandate_id)" do
      payment_table = sql[/CREATE TABLE "kiosk"\.payment_mandates.*?\);/m]
      expect(payment_table).to include("mandate_id")
      expect(payment_table).to include("payment_method")
      expect(payment_table).to include("amount_cents")
      expect(payment_table).to include("UNIQUE (user_id, mandate_id)")
    end

    it "the settlements table carries psp_reference and settled_amount_cents" do
      settlements_table = sql[/CREATE TABLE "kiosk"\.settlements.*?\);/m]
      expect(settlements_table).to include("psp_reference")
      expect(settlements_table).to include("settled_amount_cents")
    end
  end

  describe ".device_authorizations_sql" do
    subject(:sql) { described_class.device_authorizations_sql }

    # ONE create, in the final shape. Until K-646 this table arrived as an 0.1
    # shape nothing ever wrote plus a `rebuild` that DROPPED and recreated it —
    # so the generator must not emit a DROP any more, and a re-run that found
    # one would mean the fold had been undone.
    it "creates the table outright, with no DROP to undo an earlier shape" do
      expect(sql).to include(%(CREATE TABLE "kiosk".device_authorizations))
      expect(sql).not_to include("DROP TABLE")
    end

    it "stores both codes hashed only (text hex digests, no plaintext user_code)" do
      expect(sql).to include("device_code_hash text NOT NULL")
      expect(sql).to include("user_code_hash   text NOT NULL")
      expect(sql).not_to match(/\buser_code\s+text/)
    end

    it "carries the binding columns: public_key_pem + kind (claim/link)" do
      expect(sql).to include("public_key_pem   text")
      expect(sql).to include("kind             text NOT NULL DEFAULT 'claim'")
      expect(sql).to include("CHECK (kind IN ('claim', 'link'))")
    end

    it "enforces device_code uniqueness and pending-only user_code uniqueness" do
      expect(sql).to include("CREATE UNIQUE INDEX idx_device_authorizations_code_hash")
      expect(sql).to match(/idx_device_authorizations_user_code_pending.*?WHERE status = 'pending'/m)
    end

    it "types user_id against the provider's user-id type" do
      out = described_class.device_authorizations_sql(user_id_type: :bigint)
      expect(out).to include("user_id          bigint")
    end
  end

  describe ".user_id_cast" do
    it "maps :uuid to 'uuid'" do
      expect(described_class.user_id_cast(:uuid)).to eq("uuid")
    end

    it "maps :bigint to 'bigint'" do
      expect(described_class.user_id_cast(:bigint)).to eq("bigint")
    end

    it "maps :integer to 'integer'" do
      expect(described_class.user_id_cast(:integer)).to eq("integer")
    end

    it "maps :text to 'text'" do
      expect(described_class.user_id_cast(:text)).to eq("text")
    end

    it "rejects unknown types" do
      expect { described_class.user_id_cast(:bigserial) }
        .to raise_error(ArgumentError, /user_id_type/)
    end
  end
end
