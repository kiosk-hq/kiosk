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
      expect(sql).to include("user_id         uuid NOT NULL REFERENCES \"users\"(id)")
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
      expect(out).to include("user_id         bigint NOT NULL")
    end
  end

  describe ".actions_log_sql" do
    subject(:sql) { described_class.actions_log_sql }

    it "creates `kiosk.actions` registry and `kiosk.action_log` for invocation records" do
      expect(sql).to include(%(CREATE TABLE "kiosk".actions))
      expect(sql).to include(%(CREATE TABLE "kiosk".action_log))
    end

    it "records actor + agent_id + role per invocation" do
      expect(sql).to include("agent_id      uuid")
      expect(sql).to include("role          text NOT NULL")
      expect(sql).to include("actor         text NOT NULL")
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
