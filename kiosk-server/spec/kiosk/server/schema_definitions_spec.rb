# frozen_string_literal: true

RSpec.describe Kiosk::Server::SchemaDefinitions do
  describe '.helper_functions_sql' do
    subject(:sql) { described_class.helper_functions_sql }

    it 'creates the schema (idempotent)' do
      expect(sql).to include(%(CREATE SCHEMA IF NOT EXISTS "kiosk"))
    end

    it 'defines all four current_*() helpers' do
      %w[current_user_id current_role current_actor current_agent_id].each do |fn|
        expect(sql).to include(%(FUNCTION "kiosk".#{fn}()))
      end
    end

    it 'marks the helpers as STABLE' do
      expect(sql.scan('LANGUAGE sql STABLE').size).to eq(4)
    end

    it 'types current_user_id() against the configured user-id type (default :uuid)' do
      expect(sql).to include('current_user_id() RETURNS uuid')
      expect(sql).to include('::uuid')
    end

    it 'types current_user_id() against :bigint when configured' do
      Kiosk.configure { |c| c.user_id_type = :bigint }
      out = described_class.helper_functions_sql
      expect(out).to include('current_user_id() RETURNS bigint')
      expect(out).to include('::bigint')
    end

    it "uses the configured GUC namespace (default 'app')" do
      expect(sql).to include("current_setting('app.current_user_id', true)")
    end

    it 'uses an overridden GUC namespace' do
      Kiosk.configure { |c| c.guc_namespace = 'kiosk-all' }
      out = described_class.helper_functions_sql
      expect(out).to include("current_setting('kiosk-all.current_user_id', true)")
    end

    it 'uses an overridden schema name' do
      Kiosk.configure { |c| c.schema = 'ksk' }
      out = described_class.helper_functions_sql
      expect(out).to include(%(CREATE SCHEMA IF NOT EXISTS "ksk"))
      expect(out).to include(%(FUNCTION "ksk".current_user_id()))
    end

    it 'allows explicit overrides regardless of Kiosk.configuration' do
      out = described_class.helper_functions_sql(schema: 'x', guc_namespace: 'y', user_id_type: :text)
      expect(out).to include(%(CREATE SCHEMA IF NOT EXISTS "x"))
      expect(out).to include("current_setting('y.current_user_id', true)")
      expect(out).to include('current_user_id() RETURNS text')
    end
  end

  describe '.identity_tables_sql' do
    subject(:sql) { described_class.identity_tables_sql }

    it 'creates `agents` with NOT NULL user_id FK to the configured user table' do
      expect(sql).to include(%(CREATE TABLE IF NOT EXISTS "kiosk".agents))
      expect(sql).to include('user_id             uuid NOT NULL REFERENCES "users"(id)')
    end

    it 'gives a spending cap its currency: both set or both NULL, the code lower-case' do
      expect(sql).to include('spending_cap_currency text')
      expect(sql).to include(%(CHECK ((spending_cap_cents IS NULL) = (spending_cap_currency IS NULL))))
      expect(sql).to include(%(CHECK (spending_cap_currency ~ '^[a-z]{3}$')))
    end

    it 'creates `agent_tokens` with FK to agents and a unique token_hash' do
      expect(sql).to include(%(CREATE TABLE IF NOT EXISTS "kiosk".agent_tokens))
      expect(sql).to include(%(REFERENCES "kiosk".agents(id) ON DELETE CASCADE))
      expect(sql).to include(%(UNIQUE INDEX IF NOT EXISTS idx_agent_tokens_hash))
    end

    it 'creates `agent_mappings` for external-IdP subject ↔ local agent linkage' do
      expect(sql).to include(%(CREATE TABLE IF NOT EXISTS "kiosk".agent_mappings))
      expect(sql).to include('PRIMARY KEY (provider, external_id)')
    end

    it 'creates `assistant_accounts`: each account that registration opened, and the account it merged into' do
      expect(sql).to include(%(CREATE TABLE IF NOT EXISTS "kiosk".assistant_accounts))
      expect(sql).to include('merged_into  uuid REFERENCES "users"(id) ON DELETE CASCADE')
    end

    it 'uses the configured user_table name' do
      out = described_class.identity_tables_sql(user_table: 'members')
      expect(out).to include(%(REFERENCES "members"(id)))
    end

    it 'types user_id column against :bigint when configured' do
      Kiosk.configure { |c| c.user_id_type = :bigint }
      out = described_class.identity_tables_sql
      expect(out).to include('user_id             bigint NOT NULL')
    end

    # DB-level dedupe of the credential, per origin: one key may hold a live
    # row on each origin served.
    it 'adds a PARTIAL unique index on (issuer, public_key) for LIVE rows only' do
      expect(sql).to match(
        /CREATE UNIQUE INDEX IF NOT EXISTS idx_agents_issuer_public_key_live\s+ON "kiosk"\.agents \(issuer, public_key\) WHERE revoked_at IS NULL/
      )
      expect(sql).not_to include('idx_agents_public_key_live')
    end

    it 'keeps the public_key uniqueness partial so a revoked key can re-register' do
      # A bare (non-partial) UNIQUE would block re-registering a revoked key —
      # the index MUST be scoped to revoked_at IS NULL.
      expect(sql).not_to match(/idx_agents_issuer_public_key_live\s+ON "kiosk"\.agents \(issuer, public_key\);/)
    end

    it 'declares issuer NOT NULL with no default, the last column on agents' do
      agents = sql[/CREATE TABLE IF NOT EXISTS "kiosk"\.agents.*?\n\);/m]
      expect(agents).to match(/revoked_at\s+timestamptz,\s+issuer\s+text NOT NULL,\s+CONSTRAINT/)
    end

    # Nullable, and free to an operator who never uses them.
    it 'declares spending_cap_cents and human_label on agents, and no KYC column' do
      agents = sql[/CREATE TABLE IF NOT EXISTS "kiosk"\.agents.*?\);/m]
      expect(agents).not_to include('kyc')
      expect(agents).to include('spending_cap_cents  bigint')
      expect(agents).to include('human_label         text')
    end
  end

  describe 'replay safety (K-1083)' do
    # Found rather than listed: the emitters are this module's own `*_sql`
    # singleton methods, so an eleventh is covered the day it is defined.
    let(:emitter_names) { described_class.singleton_methods(false).grep(/_sql\z/).sort }

    before do
      stub_const('User', Class.new { def self.table_name = 'users' })
      Kiosk.configure do |c|
        c.issuer     = 'https://a.example'
        c.user_model = 'User'
      end
    end

    it 'guards every CREATE it emits, so a second run against the same database is a no-op' do
      expect(emitter_names).not_to be_empty

      unguarded = emitter_names.flat_map do |name|
        described_class.public_send(name).lines.grep(/^\s*CREATE /)
                       .reject { |line| line.include?('IF NOT EXISTS') || line.include?('CREATE OR REPLACE') }
                       .map { |line| "#{name}: #{line}" }
      end

      expect(unguarded).to be_empty,
                           'these CREATEs abort db:migrate on a database that already has the object, ' \
                           "stranding every later migration:\n#{unguarded.join}"
    end
  end

  describe 'the retired actions-log generator' do
    it 'no longer exists' do
      expect(described_class).not_to respond_to(:actions_log_sql)
    end

    # A shim would be a second way to build the same schema.
    it 'leaves no amendment generator behind either' do
      expect(described_class).not_to respond_to(:kyc_verified_at_sql)
      expect(described_class).not_to respond_to(:agent_governance_columns_sql)
      expect(described_class).not_to respond_to(:rebuild_device_authorizations_sql)
    end

    it 'is emitted by no other canonical generator' do
      sql = [described_class.helper_functions_sql, described_class.identity_tables_sql,
             described_class.device_authorizations_sql,
             described_class.mandates_sql].join("\n")
      expect(sql).not_to include('action_log')
      expect(sql).not_to include(%(CREATE TABLE IF NOT EXISTS "kiosk".actions))
    end
  end

  describe '.mandates_sql' do
    subject(:sql) { described_class.mandates_sql(schema: 'kiosk', user_id_type: :uuid) }

    it 'creates the two signed mandate tables and the settlements receipt table' do
      expect(sql).to include('CREATE TABLE IF NOT EXISTS "kiosk".checkout_mandates')
      expect(sql).to include('CREATE TABLE IF NOT EXISTS "kiosk".payment_mandates')
      expect(sql).to include('CREATE TABLE IF NOT EXISTS "kiosk".settlements')
      expect(sql).not_to include('intent_mandates')
    end

    it 'links payment→checkout and settlement→checkout by FK' do
      expect(sql.scan('REFERENCES "kiosk".checkout_mandates(id)').size).to eq(2)
    end

    it 'stores money as bigint cents and keeps each signed SD-JWT' do
      expect(sql).to include('total_amount_cents bigint')
      expect(sql).to include('settled_amount_cents bigint')
      expect(sql.scan(/sd_jwt +text NOT NULL/).size).to eq(2)
    end

    # The two SIGNED mandate tables each carry the SD-JWT the assistant
    # signed; a settlement is a server-minted receipt nobody signs.
    it 'gives settlements NO sd_jwt column — nobody signs a server-minted receipt' do
      settlements_table = sql[/CREATE TABLE IF NOT EXISTS "kiosk"\.settlements.*?\);/m]
      expect(settlements_table).not_to match(/^\s*sd_jwt\s+\w/)
    end

    it 'keeps a server-generated uuid PK on every table (never caller-supplied)' do
      expect(sql.scan(/\bid +uuid PRIMARY KEY DEFAULT gen_random_uuid\(\)/).size).to eq(3)
    end

    it 'keys each signed mandate by its reference, unique per principal' do
      expect(sql.scan(/^ *reference +text NOT NULL/).size).to eq(2)
      expect(sql.scan('UNIQUE (user_id, reference)').size).to eq(2)
    end

    it 'holds one live checkout mandate per checkout: a declined one frees it' do
      expect(sql).to include('ON "kiosk".checkout_mandates (user_id, checkout_hash) WHERE declined_at IS NULL')
      expect(sql).to include('CREATE UNIQUE INDEX IF NOT EXISTS idx_checkout_mandates_live_checkout')
    end

    it 'anchors idempotency with one settlement per checkout mandate on settlements' do
      expect(sql).to include('UNIQUE (checkout_mandate_id)')
    end

    it 'the signed payment_mandates table carries reference, payment_instrument and amount_cents' do
      payment_table = sql[/CREATE TABLE IF NOT EXISTS "kiosk"\.payment_mandates.*?\);/m]
      expect(payment_table).to include('reference', 'payment_instrument', 'amount_cents', 'UNIQUE (user_id, reference)')
    end

    it 'the settlements table carries psp_reference and settled_amount_cents' do
      settlements_table = sql[/CREATE TABLE IF NOT EXISTS "kiosk"\.settlements.*?\);/m]
      expect(settlements_table).to include('psp_reference')
      expect(settlements_table).to include('settled_amount_cents')
    end
  end

  describe '.device_authorizations_sql' do
    subject(:sql) { described_class.device_authorizations_sql }

    # ONE create, in the final shape, with no DROP.
    it 'creates the table outright, with no DROP to undo an earlier shape' do
      expect(sql).to include(%(CREATE TABLE IF NOT EXISTS "kiosk".device_authorizations))
      expect(sql).not_to include('DROP TABLE')
    end

    it 'stores both codes hashed only (text hex digests, no plaintext user_code)' do
      expect(sql).to include('device_code_hash text NOT NULL')
      expect(sql).to include('user_code_hash   text NOT NULL')
      expect(sql).not_to match(/\buser_code\s+text/)
    end

    it 'carries the binding columns: public_key_pem + kind (claim/link)' do
      expect(sql).to include('public_key_pem   text')
      expect(sql).to include("kind             text NOT NULL DEFAULT 'claim'")
      expect(sql).to include("CHECK (kind IN ('claim', 'link'))")
    end

    it 'enforces device_code uniqueness and pending-only user_code uniqueness' do
      expect(sql).to include('CREATE UNIQUE INDEX IF NOT EXISTS idx_device_authorizations_code_hash')
      expect(sql).to match(/idx_device_authorizations_user_code_pending.*?WHERE status = 'pending'/m)
    end

    it "types user_id against the provider's user-id type" do
      out = described_class.device_authorizations_sql(user_id_type: :bigint)
      expect(out).to include('user_id          bigint')
    end
  end

  describe '.user_id_cast' do
    it "maps :uuid to 'uuid'" do
      expect(described_class.user_id_cast(:uuid)).to eq('uuid')
    end

    it "maps :bigint to 'bigint'" do
      expect(described_class.user_id_cast(:bigint)).to eq('bigint')
    end

    it "maps :integer to 'integer'" do
      expect(described_class.user_id_cast(:integer)).to eq('integer')
    end

    it "maps :text to 'text'" do
      expect(described_class.user_id_cast(:text)).to eq('text')
    end

    it 'rejects unknown types' do
      expect { described_class.user_id_cast(:bigserial) }
        .to raise_error(ArgumentError, /user_id_type/)
    end
  end
end
