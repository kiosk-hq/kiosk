# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "rails/generators"
require_relative "../../../lib/generators/kiosk/install/install_generator"

RSpec.describe Kiosk::Generators::InstallGenerator do
  around do |example|
    Dir.mktmpdir do |dir|
      @destination = dir
      example.run
    end
  end

  # Drive the generator entirely off-disk so each spec is hermetic.
  # Thor's shell writes `create  …` chatter to $stdout — swap that for a
  # StringIO so RSpec output stays clean.
  def invoke!(args = [])
    original_stdout = $stdout
    $stdout = StringIO.new
    described_class.start(args, destination_root: @destination)
  ensure
    $stdout = original_stdout
  end

  def read(relative)
    File.read(File.join(@destination, relative))
  end

  def migrations
    Dir[File.join(@destination, "db/migrate/*.rb")].sort
  end

  describe "initializer" do
    it "creates config/initializers/kiosk.rb" do
      invoke!
      expect(File).to exist(File.join(@destination, "config/initializers/kiosk.rb"))
    end

    it "wraps the configuration in a Kiosk.configure block" do
      invoke!
      expect(read("config/initializers/kiosk.rb")).to include("Kiosk.configure do |c|")
    end

    it "wires the default user model (singularised classified table name)" do
      invoke!
      expect(read("config/initializers/kiosk.rb")).to include('c.user_model     = "User"')
    end

    it "wires the default user_id_type (:uuid)" do
      invoke!
      expect(read("config/initializers/kiosk.rb")).to include("c.user_id_type   = :uuid")
    end

    it "honours --user-table by classifying it" do
      invoke!(%w[--user-table=members])
      expect(read("config/initializers/kiosk.rb")).to include('c.user_model     = "Member"')
    end

    it "honours --user-id-type" do
      invoke!(%w[--user-id-type=bigint])
      expect(read("config/initializers/kiosk.rb")).to include("c.user_id_type   = :bigint")
    end

    it "comments overrideable Postgres settings with the chosen defaults" do
      invoke!(%w[--schema=ksk --guc-namespace=kiosk-all])
      body = read("config/initializers/kiosk.rb")
      expect(body).to include('# c.guc_namespace = "kiosk-all"')
      expect(body).to include('# c.schema = "ksk"')
    end

    it "documents pluggable IdP adapters" do
      invoke!
      body = read("config/initializers/kiosk.rb")
      expect(body).to include("# c.user_idp")
      expect(body).to include("# c.agent_idp")
    end

    it "emits an active, empty c.handlers slot (K-761 class: a fresh app has no handler " \
       "controllers yet, so the generator cannot name real classes without breaking boot)" do
      invoke!
      body = read("config/initializers/kiosk.rb")
      expect(body).to include("c.handlers = []")
    end

    it "does not comment out the c.handlers assignment — a commented line risks being " \
       "skipped, leaving the origin in the dead-catalog state this line exists to prevent" do
      invoke!
      body = read("config/initializers/kiosk.rb")
      expect(body).not_to match(/^\s*#\s*c\.handlers\s*=\s*\[\]/)
    end

    it "explains the dead-origin consequence of leaving c.handlers empty" do
      invoke!
      body = read("config/initializers/kiosk.rb")
      expect(body).to include("serves NO verbs")
      expect(body).to include('"capabilities": []')
    end

    it "shows the fill-in-later syntax with example handler class names" do
      invoke!
      body = read("config/initializers/kiosk.rb")
      expect(body).to include("c.handlers = %w[Kiosk::CatalogController Kiosk::OrdersController]")
    end
  end

  describe "migrations" do
    it "creates exactly the six canonical migrations (001-006)" do
      invoke!
      expect(migrations.size).to eq(6)
      basenames = migrations.map { |p| File.basename(p) }
      expect(basenames).to include(
        a_string_ending_with("_create_kiosk_schema.rb"),
        a_string_ending_with("_create_kiosk_identity_tables.rb"),
        a_string_ending_with("_create_kiosk_reservations.rb"),
        a_string_ending_with("_create_kiosk_device_authorizations.rb"),
        a_string_ending_with("_create_kiosk_mandates.rb"),
        a_string_ending_with("_create_kiosk_kyc_attributes.rb"),
      )
    end

    # THE SHAPE, not merely the count (K-646). Every canonical migration is a
    # `create_`: the set that shipped until 2026-08-20 also carried a `rebuild_`
    # of a table it had created two files earlier and three `add_*_to_*`
    # amendments of a table created two files before THAT, so a fresh adopter
    # ran a history to reach a schema these six state outright. A new amendment
    # migration is how that grows back, and this is what refuses it.
    it "emits nothing but `create_` migrations — no rebuilds, no amendments" do
      invoke!
      basenames = migrations.map { |p| File.basename(p).sub(/\A\d+_/, "") }
      expect(basenames).to all(start_with("create_kiosk_"))
      expect(basenames).not_to include(a_string_starting_with("rebuild_"), a_string_starting_with("add_"))
    end

    it "orders the migration timestamps in 001 → 006 sequence" do
      invoke!
      timestamps = migrations.map { |p| File.basename(p).split("_").first.to_i }
      expect(timestamps).to eq(timestamps.sort)
      expect(timestamps.uniq.size).to eq(6) # strictly ascending, no collisions
    end

    describe "001 create_kiosk_schema" do
      let(:file) { migrations.find { |p| p.end_with?("_create_kiosk_schema.rb") } }

      it "is generated" do
        invoke!
        expect(file).not_to be_nil
      end

      it "calls SchemaDefinitions.helper_functions_sql with the configured args" do
        invoke!(%w[--schema=ksk --guc-namespace=kiosk-all --user-id-type=bigint])
        body = File.read(file)
        expect(body).to include("Kiosk::Server::SchemaDefinitions.helper_functions_sql(")
        expect(body).to include('schema:        "ksk"')
        expect(body).to include('guc_namespace: "kiosk-all"')
        expect(body).to include("user_id_type:  :bigint")
      end

      it "is reversible — drops the schema CASCADE" do
        invoke!(%w[--schema=ksk])
        expect(File.read(file)).to include('DROP SCHEMA IF EXISTS "ksk" CASCADE')
      end

      it "subclasses ActiveRecord::Migration with the host's current version" do
        invoke!
        expect(File.read(file))
          .to include("ActiveRecord::Migration[ActiveRecord::Migration.current_version]")
      end
    end

    describe "002 create_kiosk_identity_tables" do
      let(:file) { migrations.find { |p| p.end_with?("_create_kiosk_identity_tables.rb") } }

      it "calls SchemaDefinitions.identity_tables_sql with schema, user_id_type, user_table" do
        invoke!(%w[--user-table=members --user-id-type=bigint --schema=ksk])
        body = File.read(file)
        expect(body).to include("Kiosk::Server::SchemaDefinitions.identity_tables_sql(")
        expect(body).to include('schema:       "ksk"')
        expect(body).to include("user_id_type: :bigint")
        expect(body).to include('user_table:   "members"')
      end

      it "drops the three tables in reverse-FK order in #down" do
        invoke!(%w[--schema=ksk])
        body = File.read(file)
        mappings_idx = body.index('DROP TABLE IF EXISTS "ksk".agent_mappings')
        tokens_idx   = body.index('DROP TABLE IF EXISTS "ksk".agent_tokens')
        agents_idx   = body.index('DROP TABLE IF EXISTS "ksk".agents')
        expect(mappings_idx).to be < tokens_idx
        expect(tokens_idx).to be < agents_idx
      end
    end

    describe "003 create_kiosk_reservations" do
      let(:file) { migrations.find { |p| p.end_with?("_create_kiosk_reservations.rb") } }

      it "calls SchemaDefinitions.reservations_sql with the configured args" do
        invoke!(%w[--schema=ksk --user-id-type=bigint])
        body = File.read(file)
        expect(body).to include("Kiosk::Server::SchemaDefinitions.reservations_sql(")
        expect(body).to include('schema:       "ksk"')
        expect(body).to include("user_id_type: :bigint")
      end

      it "drops the reservations table in #down" do
        invoke!(%w[--schema=ksk])
        expect(File.read(file)).to include('DROP TABLE IF EXISTS "ksk".reservations')
      end
    end

    describe "004 create_kiosk_device_authorizations" do
      let(:file) { migrations.find { |p| p.end_with?("_create_kiosk_device_authorizations.rb") } }

      it "calls SchemaDefinitions.device_authorizations_sql with the configured args" do
        invoke!(%w[--schema=ksk --user-id-type=bigint])
        body = File.read(file)
        expect(body).to include("Kiosk::Server::SchemaDefinitions.device_authorizations_sql(")
        expect(body).to include('schema:       "ksk"')
        expect(body).to include("user_id_type: :bigint")
      end

      it "drops the device_authorizations table in #down" do
        invoke!(%w[--schema=ksk])
        expect(File.read(file)).to include('DROP TABLE IF EXISTS "ksk".device_authorizations')
      end
    end

    describe "005 create_kiosk_mandates" do
      let(:file) { migrations.find { |p| p.end_with?("_create_kiosk_mandates.rb") } }

      it "calls SchemaDefinitions.mandates_sql with the configured args" do
        invoke!(%w[--schema=ksk --user-id-type=bigint])
        body = File.read(file)
        expect(body).to include("Kiosk::Server::SchemaDefinitions.mandates_sql(")
        expect(body).to include('schema:       "ksk"')
        expect(body).to include("user_id_type: :bigint")
      end

      it "drops all four mandate tables — including settlements — in reverse-FK order in #down" do
        invoke!(%w[--schema=ksk])
        body = File.read(file)
        payment_idx     = body.index('DROP TABLE IF EXISTS "ksk".payment_mandates')
        settlements_idx = body.index('DROP TABLE IF EXISTS "ksk".settlements')
        cart_idx        = body.index('DROP TABLE IF EXISTS "ksk".cart_mandates')
        intent_idx      = body.index('DROP TABLE IF EXISTS "ksk".intent_mandates')
        # settlements is created by mandates_sql with a FK to cart_mandates, so a
        # down that never drops it — or drops cart_mandates first — fails on the
        # FK dependency during db:rollback.
        expect(settlements_idx).not_to be_nil
        # Both payment_mandates and settlements reference cart_mandates; both drop
        # before it. cart_mandates references intent_mandates; it drops before that.
        expect(payment_idx).to be < cart_idx
        expect(settlements_idx).to be < cart_idx
        expect(cart_idx).to be < intent_idx
      end
    end

    describe "006 create_kiosk_kyc_attributes" do
      let(:file) { migrations.find { |p| p.end_with?("_create_kiosk_kyc_attributes.rb") } }

      it "calls SchemaDefinitions.kyc_attributes_sql with the configured schema" do
        invoke!(%w[--schema=ksk])
        body = File.read(file)
        expect(body).to include("Kiosk::Server::SchemaDefinitions.kyc_attributes_sql(")
        expect(body).to include('schema: "ksk"')
      end

      it "sorts after 002 (the agents table its rows reference)" do
        invoke!
        identity_idx   = migrations.index { |p| p.end_with?("_create_kiosk_identity_tables.rb") }
        attributes_idx = migrations.index { |p| p.end_with?("_create_kiosk_kyc_attributes.rb") }
        expect(attributes_idx).to be > identity_idx
      end

      it "drops the TABLE in #down" do
        invoke!(%w[--schema=ksk])
        expect(File.read(file)).to include('DROP TABLE IF EXISTS "ksk".kyc_attributes')
      end
    end
  end

  describe "default options" do
    it "uses :uuid, schema 'kiosk', guc 'app', table 'users' when no flags are passed" do
      invoke!
      schema_migration = migrations.find { |p| p.end_with?("_create_kiosk_schema.rb") }
      body = File.read(schema_migration)
      expect(body).to include('schema:        "kiosk"')
      expect(body).to include('guc_namespace: "app"')
      expect(body).to include("user_id_type:  :uuid")
    end
  end
end
