# frozen_string_literal: true

require 'spec_helper'
require_relative '../../support/postgres'

# Runs against a real Postgres: a throwaway schema with the two `agents`
# columns the store reads and the shipped `revocations` table. No reachable
# server → skip.
module RevocationStoresSpec
  SCHEMA = 'kiosk_revocation_store_spec'

  def self.create_schema
    SpecPostgres.recreate_schema(SCHEMA)
    conn = ActiveRecord::Base.connection
    conn.execute(%(CREATE TABLE "#{SCHEMA}".agents (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), revoked_at timestamptz)))
    conn.execute(Kiosk::Server::SchemaDefinitions.revocations_sql(schema: SCHEMA))
  end

  def insert_agent
    ActiveRecord::Base.connection.exec_query(%(INSERT INTO "#{SCHEMA}".agents DEFAULT VALUES RETURNING id)).first.fetch('id')
  end

  def unlink(agent_id)
    ActiveRecord::Base.connection.exec_query(
      %(UPDATE "#{SCHEMA}".agents SET revoked_at = now() WHERE id = $1), 'spec unlink', [agent_id]
    )
  end
end

RSpec.shared_context 'with a revocation Postgres schema' do
  include RevocationStoresSpec

  before do
    skip "no local Postgres reachable (#{SpecPostgres.error})" if SpecPostgres.error
    RevocationStoresSpec.create_schema
  end

  after { SpecPostgres.drop_schema(RevocationStoresSpec::SCHEMA) }

  before { Kiosk.configure { |c| c.schema = RevocationStoresSpec::SCHEMA } }

  let(:agent) { insert_agent }
  let(:now)   { Time.now.to_i }
end

RSpec.describe Kiosk::Server::RevocationStores::ActiveRecord do
  describe 'watermark' do
    include_context 'with a revocation Postgres schema'

    it 'revokes a token issued before the watermark and keeps one issued at or after it' do
      described_class.new.revoke_all(agent, at: now)

      expect(described_class.new.revoked?(agent_id: agent, iat: now - 1)).to be(true)
      expect(described_class.new.revoked?(agent_id: agent, iat: now)).to be(false)
    end

    # A second instance stands in for a second process, or the same process after a restart.
    it 'holds a revoke made through another store instance' do
      described_class.new.revoke_all(agent, at: now)

      expect(described_class.new.watermark_for(agent)).to eq(now)
    end

    it 'only moves the watermark forward' do
      store = described_class.new
      store.revoke_all(agent, at: now + 100)
      store.revoke_all(agent, at: now)

      expect(store.watermark_for(agent)).to eq(now + 100)
    end
  end

  describe 'agent row' do
    include_context 'with a revocation Postgres schema'

    it 'revokes every token of an unlinked agent, whatever its iat' do
      unlink(agent)

      expect(described_class.new.revoked?(agent_id: agent, iat: now + 3600)).to be(true)
    end

    it 'revokes a token whose agent no longer exists' do
      expect(described_class.new.revoked?(agent_id: SecureRandom.uuid, iat: now)).to be(true)
    end

    it 'keeps a token of a live agent that was never revoked' do
      expect(described_class.new.revoked?(agent_id: agent, iat: now)).to be(false)
      expect(described_class.new.watermark_for(agent)).to be_nil
    end
  end
end
