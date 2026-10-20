# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'rails/generators'
require_relative '../../../lib/generators/kiosk/install/install_generator'

module InstallGeneratorSpecHelpers
  # A host Rails app, reduced to the files the generator writes INTO:
  # `config/routes.rb` is where the `kiosk` block lands.
  HOST_ROUTES = <<~RUBY
    Rails.application.routes.draw do
      root "home#index"
    end
  RUBY

  HOST_APPLICATION = <<~RUBY
    module Host
      class Application < Rails::Application
      end
    end
  RUBY

  # Drive the generator entirely off-disk so each spec is hermetic.
  # Thor's shell writes `create  …` chatter to $stdout — swap that for a
  # StringIO so RSpec output stays clean.
  def invoke!(args = [])
    original_stdout = $stdout
    $stdout = StringIO.new
    described_class.start(args, destination_root: destination)
  ensure
    $stdout = original_stdout
  end

  # The host app's root directory, set by the shared context's `around` hook.
  attr_reader :destination

  def read(relative)
    File.read(File.join(destination, relative))
  end

  def migrations
    Dir[File.join(destination, 'db/migrate/*.rb')]
  end

  # The SQL a generated migration executes in `up`, as its heredoc yields it.
  def ddl_of(path)
    File.read(path)[/<<~'SQL'\n(.*?)^    SQL$/m, 1].gsub(/^ {6}/, '')
  end

  def routes_code
    read('config/routes.rb').lines.map(&:strip).reject { |l| l.empty? || l.start_with?('#') }
  end
end

RSpec.shared_context 'install generator spec: host app' do
  include InstallGeneratorSpecHelpers

  around do |example|
    Dir.mktmpdir do |dir|
      @destination = dir
      FileUtils.mkdir_p(File.join(dir, 'config'))
      File.write(File.join(dir, 'config/routes.rb'), InstallGeneratorSpecHelpers::HOST_ROUTES)
      File.write(File.join(dir, 'config/application.rb'), InstallGeneratorSpecHelpers::HOST_APPLICATION)
      example.run
    end
  end
end

RSpec.describe Kiosk::Generators::InstallGenerator do
  describe 'initializer' do
    include_context 'install generator spec: host app'

    it 'creates config/initializers/kiosk.rb' do
      invoke!
      expect(File).to exist(File.join(destination, 'config/initializers/kiosk.rb'))
    end

    it 'wraps the configuration in a Kiosk.configure block' do
      invoke!
      expect(read('config/initializers/kiosk.rb')).to include('Kiosk.configure do |c|')
    end

    it 'wires the default user model (singularised classified table name)' do
      invoke!
      expect(read('config/initializers/kiosk.rb')).to include('c.user_model     = "User"')
    end

    it 'wires the default user_id_type (:uuid)' do
      invoke!
      expect(read('config/initializers/kiosk.rb')).to include('c.user_id_type   = :uuid')
    end
  end

  describe 'initializer options' do
    include_context 'install generator spec: host app'

    it 'honours --user-table by classifying it' do
      invoke!(%w[--user-table=members])
      expect(read('config/initializers/kiosk.rb')).to include('c.user_model     = "Member"')
    end

    it 'honours --user-id-type' do
      invoke!(%w[--user-id-type=bigint])
      expect(read('config/initializers/kiosk.rb')).to include('c.user_id_type   = :bigint')
    end

    it 'comments overrideable Postgres settings with the chosen defaults' do
      invoke!(%w[--schema=ksk --guc-namespace=kiosk-all])
      body = read('config/initializers/kiosk.rb')
      expect(body).to include('# c.guc_namespace = "kiosk-all"')
      expect(body).to include('# c.schema = "ksk"')
    end

    it 'documents pluggable IdP adapters' do
      invoke!
      body = read('config/initializers/kiosk.rb')
      expect(body).to include('# c.user_idp')
      expect(body).to include('# c.agent_idp')
    end
  end

  # A generated app checks its own responses outside production.
  describe 'initializer validation flags' do
    include_context 'install generator spec: host app'

    it "gates response validation off production — the engine's own hazard, in a fresh app" do
      invoke!
      body = read('config/initializers/kiosk.rb')
      expect(body).to match(/^\s*c\.validate_responses\s*=\s*!Rails\.env\.production\?\s*$/)
      expect(body).not_to match(/^\s*c\.validate_responses\s*=\s*true\s*$/)
    end

    it 'writes it as an ACTIVE line — a commented posture is not a posture' do
      invoke!
      expect(read('config/initializers/kiosk.rb')).not_to match(/^\s*#\s*c\.validate_responses\s*=/)
    end

    # Input validation is enforced in VerbController behind no flag; the
    # generated file says so beside the one flag it writes.
    it 'says outright that per-verb input validation is NOT this flag' do
      invoke!
      body = read('config/initializers/kiosk.rb')
      expect(body).to include('coerce-then-validate on the per-verb wire is UNCONDITIONAL')
      expect(body).to include('input_schema')
    end
  end

  # Bundling kiosk-server draws no route: the engine installs its surface only
  # when it is mounted, so the generator writes the `kiosk` block that mounts it.
  describe 'wire routes' do
    include_context 'install generator spec: host app'

    it 'writes a `kiosk` block FIRST inside the routes block, so the protocol plane wins by first match' do
      invoke!
      expect(routes_code[1]).to eq('kiosk do')
      expect(routes_code[2]).to eq('end')
    end

    it 'draws no verb of its own — a fresh app declares none' do
      invoke!
      expect(routes_code.grep(/\A(queries|actions)\b/)).to be_empty
    end

    it 'shows where queries and actions go' do
      invoke!
      body = read('config/routes.rb')
      expect(body).to include('# queries :catalog')
      expect(body).to include('# actions :place_order')
    end

    it "leaves the host's own routes alone" do
      invoke!
      expect(read('config/routes.rb')).to include('root "home#index"')
    end

    it 'writes no separate routes file' do
      invoke!
      expect(Dir[File.join(destination, 'config/routes/*')]).to be_empty
    end
  end

  describe 'config/application.rb' do
    include_context 'install generator spec: host app'

    it 'dumps every schema, so schema.rb carries the kiosk tables' do
      invoke!
      expect(read('config/application.rb')).to include(%(config.active_record.dump_schemas = "public,kiosk"))
    end
  end

  describe 'migrations' do
    include_context 'install generator spec: host app'

    it 'creates exactly the eleven canonical migrations' do
      invoke!
      expect(migrations.size).to eq(11)
      basenames = migrations.map { |p| File.basename(p) }
      expect(basenames).to include(
        a_string_ending_with('_create_kiosk_schema.rb'),
        a_string_ending_with('_create_kiosk_identity_tables.rb'),
        a_string_ending_with('_create_kiosk_device_authorizations.rb'),
        a_string_ending_with('_create_kiosk_mandates.rb'),
        a_string_ending_with('_create_kiosk_kyc_attributes.rb'),
        a_string_ending_with('_create_kiosk_events.rb'),
        a_string_ending_with('_create_kiosk_pow_spent.rb'),
        a_string_ending_with('_create_kiosk_revocations.rb'),
        a_string_ending_with('_create_kiosk_auth_challenges.rb'),
        a_string_ending_with('_create_kiosk_visits.rb'),
        a_string_ending_with('_create_kiosk_refunds.rb')
      )
    end
  end

  describe 'migrations shape and order' do
    include_context 'install generator spec: host app'

    # The shape, not merely the count: every canonical migration creates its
    # tables in their final shape, so a fresh install replays no history.
    it 'emits nothing but `create_` migrations — no rebuilds, no amendments' do
      invoke!
      basenames = migrations.map { |p| File.basename(p).sub(/\A\d+_/, '') }
      expect(basenames).to all(start_with('create_kiosk_'))
      expect(basenames).not_to include(a_string_starting_with('rebuild_'), a_string_starting_with('add_'))
    end

    it 'orders the migration timestamps in 001 → 012 sequence' do
      invoke!
      timestamps = migrations.map { |p| File.basename(p).split('_').first.to_i }
      expect(timestamps).to eq(timestamps.sort)
      expect(timestamps.uniq.size).to eq(11) # strictly ascending, no collisions
    end
  end

  describe 'migrations 012 create_kiosk_refunds' do
    include_context 'install generator spec: host app'

    let(:file) { migrations.find { |p| p.end_with?('_create_kiosk_refunds.rb') } }

    it "writes refunds_sql's DDL for the configured schema" do
      invoke!(%w[--schema=ksk])
      expect(ddl_of(file)).to eq("#{Kiosk::Server::SchemaDefinitions.refunds_sql(schema: 'ksk')}\n")
    end

    it 'drops the table on down' do
      invoke!(%w[--schema=ksk])
      expect(File.read(file)).to include(%(DROP TABLE IF EXISTS "ksk".refunds))
    end
  end

  describe 'migrations 011 create_kiosk_visits' do
    include_context 'install generator spec: host app'

    let(:file) { migrations.find { |p| p.end_with?('_create_kiosk_visits.rb') } }

    it "writes visits_sql's DDL for the configured schema and user id type" do
      invoke!(%w[--schema=ksk --user_id_type=bigint])
      expect(ddl_of(file)).to eq("#{Kiosk::Server::SchemaDefinitions.visits_sql(schema: 'ksk', user_id_type: :bigint)}\n")
    end

    it 'drops the table on down' do
      invoke!(%w[--schema=ksk])
      expect(File.read(file)).to include(%(DROP TABLE IF EXISTS "ksk".visits))
    end
  end

  describe 'migrations 010 create_kiosk_auth_challenges' do
    include_context 'install generator spec: host app'

    let(:file) { migrations.find { |p| p.end_with?('_create_kiosk_auth_challenges.rb') } }

    it "writes auth_challenge_sql's DDL for the configured schema" do
      invoke!(%w[--schema=ksk])
      expect(ddl_of(file)).to eq("#{Kiosk::Server::SchemaDefinitions.auth_challenge_sql(schema: 'ksk')}\n")
    end

    it 'drops the table on down' do
      invoke!(%w[--schema=ksk])
      expect(File.read(file)).to include(%(DROP TABLE IF EXISTS "ksk".auth_challenges))
    end
  end

  describe 'migrations 009 create_kiosk_revocations' do
    include_context 'install generator spec: host app'

    let(:file) { migrations.find { |p| p.end_with?('_create_kiosk_revocations.rb') } }

    it "writes revocations_sql's DDL for the configured schema" do
      invoke!(%w[--schema=ksk])
      expect(ddl_of(file)).to eq("#{Kiosk::Server::SchemaDefinitions.revocations_sql(schema: 'ksk')}\n")
    end
  end

  describe 'migrations 008 create_kiosk_pow_spent' do
    include_context 'install generator spec: host app'

    let(:file) { migrations.find { |p| p.end_with?('_create_kiosk_pow_spent.rb') } }

    it "writes pow_spent_sql's DDL for the configured schema" do
      invoke!(%w[--schema=ksk])
      expect(ddl_of(file)).to eq("#{Kiosk::Server::SchemaDefinitions.pow_spent_sql(schema: 'ksk')}\n")
    end

    it 'drops the table on down' do
      invoke!(%w[--schema=ksk])
      expect(File.read(file)).to include(%(DROP TABLE IF EXISTS "ksk".pow_spent))
    end
  end

  describe 'migrations 007 create_kiosk_events' do
    include_context 'install generator spec: host app'

    let(:file) { migrations.find { |p| p.end_with?('_create_kiosk_events.rb') } }

    it 'is generated' do
      invoke!
      expect(file).not_to be_nil
    end

    it "writes events_sql's DDL for the configured schema" do
      invoke!(%w[--schema=ksk])
      expect(ddl_of(file)).to eq("#{Kiosk::Server::SchemaDefinitions.events_sql(schema: 'ksk')}\n")
    end

    it 'drops the table on down' do
      invoke!(%w[--schema=ksk])
      expect(File.read(file)).to include(%(DROP TABLE IF EXISTS "ksk".events))
    end
  end

  describe 'migrations 001 create_kiosk_schema' do
    include_context 'install generator spec: host app'

    let(:file) { migrations.find { |p| p.end_with?('_create_kiosk_schema.rb') } }

    it 'is generated' do
      invoke!
      expect(file).not_to be_nil
    end

    it "writes helper_functions_sql's DDL for the configured args" do
      invoke!(%w[--schema=ksk --guc-namespace=kiosk-all --user-id-type=bigint])
      expected = Kiosk::Server::SchemaDefinitions.helper_functions_sql(schema: 'ksk', guc_namespace: 'kiosk-all', user_id_type: :bigint)
      expect(ddl_of(file)).to eq("#{expected}\n")
    end

    it 'is reversible — drops the schema CASCADE' do
      invoke!(%w[--schema=ksk])
      expect(File.read(file)).to include('DROP SCHEMA IF EXISTS "ksk" CASCADE')
    end

    it "subclasses ActiveRecord::Migration with the host's current version" do
      invoke!
      expect(File.read(file))
        .to include('ActiveRecord::Migration[ActiveRecord::Migration.current_version]')
    end
  end

  describe 'migrations 002 create_kiosk_identity_tables' do
    include_context 'install generator spec: host app'

    let(:file) { migrations.find { |p| p.end_with?('_create_kiosk_identity_tables.rb') } }

    it "writes identity_tables_sql's DDL for schema, user_id_type, user_table" do
      invoke!(%w[--user-table=members --user-id-type=bigint --schema=ksk])
      expected = Kiosk::Server::SchemaDefinitions.identity_tables_sql(schema: 'ksk', user_id_type: :bigint, user_table: 'members')
      expect(ddl_of(file)).to eq("#{expected}\n")
    end

    it 'drops the three tables in reverse-FK order in #down' do
      invoke!(%w[--schema=ksk])
      body = File.read(file)
      mappings_idx = body.index('DROP TABLE IF EXISTS "ksk".agent_mappings')
      tokens_idx   = body.index('DROP TABLE IF EXISTS "ksk".agent_tokens')
      agents_idx   = body.index('DROP TABLE IF EXISTS "ksk".agents')
      expect(mappings_idx).to be < tokens_idx
      expect(tokens_idx).to be < agents_idx
    end
  end

  describe 'migrations 004 create_kiosk_device_authorizations' do
    include_context 'install generator spec: host app'

    let(:file) { migrations.find { |p| p.end_with?('_create_kiosk_device_authorizations.rb') } }

    it "writes device_authorizations_sql's DDL for the configured args" do
      invoke!(%w[--schema=ksk --user-id-type=bigint])
      expected = Kiosk::Server::SchemaDefinitions.device_authorizations_sql(schema: 'ksk', user_id_type: :bigint)
      expect(ddl_of(file)).to eq("#{expected}\n")
    end

    it 'drops the device_authorizations table in #down' do
      invoke!(%w[--schema=ksk])
      expect(File.read(file)).to include('DROP TABLE IF EXISTS "ksk".device_authorizations')
    end
  end

  describe 'migrations 005 create_kiosk_mandates' do
    include_context 'install generator spec: host app'

    let(:file) { migrations.find { |p| p.end_with?('_create_kiosk_mandates.rb') } }

    it "writes mandates_sql's DDL for the configured args" do
      invoke!(%w[--schema=ksk --user-id-type=bigint])
      expected = Kiosk::Server::SchemaDefinitions.mandates_sql(schema: 'ksk', user_id_type: :bigint)
      expect(ddl_of(file)).to eq("#{expected}\n")
    end

    it 'drops all four mandate tables — including settlements — in reverse-FK order in #down' do
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

  describe 'migrations 006 create_kiosk_kyc_attributes' do
    include_context 'install generator spec: host app'

    let(:file) { migrations.find { |p| p.end_with?('_create_kiosk_kyc_attributes.rb') } }

    it "writes kyc_attributes_sql's DDL for schema, user_id_type, user_table" do
      invoke!(%w[--schema=ksk --user-id-type=bigint --user-table=members])
      expected = Kiosk::Server::SchemaDefinitions.kyc_attributes_sql(schema: 'ksk', user_id_type: :bigint, user_table: 'members')
      expect(ddl_of(file)).to eq("#{expected}\n")
    end

    it 'sorts after 002 (the agents table its rows reference)' do
      invoke!
      identity_idx   = migrations.index { |p| p.end_with?('_create_kiosk_identity_tables.rb') }
      attributes_idx = migrations.index { |p| p.end_with?('_create_kiosk_kyc_attributes.rb') }
      expect(attributes_idx).to be > identity_idx
    end

    it 'drops the TABLE in #down' do
      invoke!(%w[--schema=ksk])
      expect(File.read(file)).to include('DROP TABLE IF EXISTS "ksk".kyc_attributes')
    end
  end

  describe 'default options' do
    include_context 'install generator spec: host app'

    it "uses :uuid, schema 'kiosk', guc 'app', table 'users' when no flags are passed" do
      invoke!
      expected = Kiosk::Server::SchemaDefinitions.identity_tables_sql(schema: 'kiosk', user_id_type: :uuid, user_table: 'users')
      expect(ddl_of(migrations.find { |p| p.end_with?('_create_kiosk_identity_tables.rb') })).to eq("#{expected}\n")
    end

    it "calls nothing at migrate time: every migration's DDL is written into it" do
      invoke!
      expect(migrations.map { |p| File.read(p) }).to all(satisfy { |body| body.exclude?('SchemaDefinitions') })
    end
  end
end
