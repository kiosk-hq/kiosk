# frozen_string_literal: true

require 'spec_helper'
require_relative '../../support/postgres'

# Runs against a real Postgres: a throwaway schema built from the shipped
# `pow_spent_sql`, dropped afterwards. No reachable server → skip, so a
# machine without Postgres stays green.
module PowSpentStoresSpec
  SCHEMA = 'kiosk_pow_spent_store_spec'

  def self.create_schema
    SpecPostgres.recreate_schema(SCHEMA)
    ActiveRecord::Base.connection.execute(Kiosk::Server::SchemaDefinitions.pow_spent_sql(schema: SCHEMA))
  end

  def expiry_row(id)
    ActiveRecord::Base.connection.exec_query(<<~SQL.squish, 'spec types', [id]).to_a.first
      SELECT pg_typeof(expires_at)::text AS at_type,
             extract(epoch FROM expires_at)::bigint AS at_epoch
      FROM "#{SCHEMA}".pow_spent
      WHERE id = $1
    SQL
  end

  def row_count(id)
    ActiveRecord::Base.connection.exec_query(
      %(SELECT count(*)::int AS n FROM "#{SCHEMA}".pow_spent WHERE id = $1), 'spec', [id]
    ).first.fetch('n')
  end
end

RSpec.shared_context 'pow spent stores spec: postgres' do
  include PowSpentStoresSpec

  subject(:store) { described_class.new }

  before do
    skip "no local Postgres reachable (#{SpecPostgres.error})" if SpecPostgres.error
    PowSpentStoresSpec.create_schema
  end

  after { SpecPostgres.drop_schema(PowSpentStoresSpec::SCHEMA) }

  let(:live) { Time.now.to_i + 300 }

  before { Kiosk.configure { |c| c.schema = PowSpentStoresSpec::SCHEMA } }
end

RSpec.describe Kiosk::Server::PowSpentStores do
  describe Kiosk::Server::PowSpentStores::ActiveRecord do
    include_context 'pow spent stores spec: postgres'

    describe 'single-use ACROSS store instances (K-738)' do
      it 'rejects a replay claimed through a second, independent store instance' do
        worker_a = described_class.new
        worker_b = described_class.new

        expect(worker_a.claim('k738-shared', live)).to be(true)
        expect(worker_b.claim('k738-shared', live)).to be(false)
      end

      it 'rejects a replay claimed on a DIFFERENT database connection' do
        # A separate thread checks out its own connection from the AR pool, so
        # the table's PRIMARY KEY decides the exclusion, not any object or
        # connection state the first claim left behind.
        expect(store.claim('k738-cross-conn', live)).to be(true)

        replay = Thread.new { described_class.new.claim('k738-cross-conn', live) }.value
        expect(replay).to be(false)
      end

      it 'leaves exactly one row for N racing claims of one id' do
        results = Array.new(4) { described_class.new.claim('k738-race', live) }

        expect(results.count(true)).to eq(1)
        expect(results.count(false)).to eq(3)
      end
    end

    describe '#claim' do
      it 'returns true the first time and false after' do
        expect(store.claim('a', live)).to be(true)
        expect(store.claim('a', live)).to be(false)
      end

      # The id and the expiry travel as bind parameters, so the type is what
      # can go wrong silently: without `to_timestamp($2)` Postgres refuses the
      # epoch integer for a timestamptz column. A hostile id is stored verbatim.
      it 'writes the expiry to the exact epoch and stores a hostile id verbatim' do
        hostile = "jti-' OR 1=1 --"
        moment  = 1_800_000_071
        expect(store.claim(hostile, moment)).to be(true)

        row = expiry_row(hostile)
        expect(row.fetch('at_type')).to eq('timestamp with time zone')
        expect(row.fetch('at_epoch')).to eq(moment)
        # The same hostile id cannot be spent twice.
        expect(store.claim(hostile, live)).to be(false)
      end

      it 'returns false for a nil id without touching the database' do
        expect(store.claim(nil, live)).to be(false)
      end

      it 're-claims an id whose expiry has already passed' do
        expired = Time.now.to_i - 1
        expect(store.claim('stale', expired)).to be(true)
        expect(store.claim('stale', live)).to be(true)
      end
    end

    describe '#release' do
      it 'un-claims an id so a legitimate retry is not blocked' do
        store.claim('b', live)
        store.release('b')
        expect(store.claim('b', live)).to be(true)
      end

      it 'is a no-op for a nil id' do
        expect { store.release(nil) }.not_to raise_error
      end
    end

    describe '#spent?' do
      it 'is false before a claim and true after' do
        expect(store.spent?('c')).to be(false)
        store.claim('c', live)
        expect(store.spent?('c')).to be(true)
      end

      it 'is false for an entry whose expiry has passed' do
        store.mark_spent('d', Time.now.to_i - 1)
        expect(store.spent?('d')).to be(false)
      end

      it 'is false for a nil id' do
        expect(store.spent?(nil)).to be(false)
      end
    end

    describe '#mark_spent' do
      it 'is idempotent and visible to a second instance' do
        store.mark_spent('e', live)
        store.mark_spent('e', live)
        expect(described_class.new.spent?('e')).to be(true)
      end

      it 'is a no-op for a nil id' do
        expect { store.mark_spent(nil, live) }.not_to raise_error
      end
    end

    it 'is accepted by Kiosk.configuration.pow_spent_store' do
      Kiosk.configure { |c| c.pow_spent_store = store }
      expect(Kiosk.configuration.pow_spent_store).to equal(store)
    end

    it 'answers the whole spent-store interface' do
      expect(store).to respond_to(:claim, :release, :spent?, :mark_spent)
    end

    describe '#prune!' do
      it 'deletes expired entries and keeps live ones' do
        store.mark_spent('gone', Time.now.to_i - 1)
        store.mark_spent('kept', live)

        store.prune!

        expect(store.claim('gone', live)).to be(true) # row was removed
        expect(store.claim('kept', live)).to be(false)
      end

      it 'is throttled on the claim path by prune_interval' do
        throttled = described_class.new(prune_interval: 10_000)
        throttled.claim('warm', live) # first claim performs the one sweep
        throttled.mark_spent('expired-after-sweep', Time.now.to_i - 1)

        throttled.claim('another', live)

        expect(row_count('expired-after-sweep')).to eq(1)
      end
    end
  end

  describe 'Kiosk::Server::SchemaDefinitions.pow_spent_sql' do
    it 'keys the table on the challenge id, so the PK is the single-use gate' do
      sql = Kiosk::Server::SchemaDefinitions.pow_spent_sql(schema: 'kiosk')

      expect(sql).to include(%(CREATE TABLE IF NOT EXISTS "kiosk".pow_spent))
      expect(sql).to include('id         text        PRIMARY KEY')
      expect(sql).to include('expires_at timestamptz NOT NULL')
    end

    it 'defaults the schema to the configured one' do
      Kiosk.configure { |c| c.schema = 'acme' }
      expect(Kiosk::Server::SchemaDefinitions.pow_spent_sql).to include(%("acme".pow_spent))
    end

    it 'is laid down by the install generator' do
      templates = Dir[File.expand_path('../../../lib/generators/kiosk/install/templates/*.tt', __dir__)]
      expect(templates.map { |p| File.basename(p) }).to include('create_kiosk_pow_spent.rb.tt')
    end
  end
end
