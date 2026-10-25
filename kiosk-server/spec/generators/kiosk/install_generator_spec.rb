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

  def routes_code
    read('config/routes.rb').lines.map(&:strip).reject { |l| l.empty? || l.start_with?('#') }
  end
end

RSpec.shared_context 'with a freshly generated host app' do
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
    include_context 'with a freshly generated host app'

    it 'creates config/initializers/kiosk.rb' do
      invoke!
      expect(File).to exist(File.join(destination, 'config/initializers/kiosk.rb'))
    end

    it 'wraps the configuration in a Kiosk.configure block' do
      invoke!
      expect(read('config/initializers/kiosk.rb')).to include('Kiosk.configure do |c|')
    end

    it 'sets the default user model (singularised classified table name)' do
      invoke!
      expect(read('config/initializers/kiosk.rb')).to include('c.user_model     = "User"')
    end

    it 'sets the default user_id_type (:uuid)' do
      invoke!
      expect(read('config/initializers/kiosk.rb')).to include('c.user_id_type   = :uuid')
    end
  end

  describe 'initializer options' do
    include_context 'with a freshly generated host app'

    it 'honours --user-table by classifying it' do
      invoke!(%w[--user-table=members])
      expect(read('config/initializers/kiosk.rb')).to include('c.user_model     = "Member"')
    end

    it 'honours --user-id-type' do
      invoke!(%w[--user-id-type=bigint])
      expect(read('config/initializers/kiosk.rb')).to include('c.user_id_type   = :bigint')
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
    include_context 'with a freshly generated host app'

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
      expect(body).to include('coerce-then-validate on the per-verb endpoints is UNCONDITIONAL')
      expect(body).to include('input_schema')
    end
  end

  # Bundling kiosk-server draws no route: the engine installs its surface only
  # when it is mounted, so the generator writes the `kiosk` block that mounts it.
  describe 'Kiosk routes' do
    include_context 'with a freshly generated host app'

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
    include_context 'with a freshly generated host app'

    it 'leaves the schema dump alone when the tables are in public' do
      invoke!
      expect(read('config/application.rb')).not_to include('dump_schemas')
    end

    it 'dumps a schema of its own, so schema.rb carries the Kiosk tables' do
      invoke!(%w[--schema=ksk])
      expect(read('config/application.rb')).to include(%(config.active_record.dump_schemas = "public,ksk"))
    end
  end

  describe 'the schema setting in the initializer' do
    include_context 'with a freshly generated host app'

    it 'comments the default' do
      invoke!
      expect(read('config/initializers/kiosk.rb')).to include('# c.schema = "public"')
    end

    it 'sets a schema of its own, which the migrations created the tables in' do
      invoke!(%w[--schema=ksk])
      expect(read('config/initializers/kiosk.rb')).to match(/^  c\.schema = "ksk"$/)
    end
  end

  describe 'migrations' do
    include_context 'with a freshly generated host app'

    let(:bodies) { migrations.sort.map { File.read(it) } }

    it 'writes the nine create_kiosk_ migrations in ascending order' do
      invoke!
      names = migrations.sort.map { File.basename(it).sub(/\A\d+_/, '').delete_suffix('.rb') }
      expect(names).to eq(described_class::MIGRATIONS.map { "create_kiosk_#{it}" })
    end

    it "subclasses ActiveRecord::Migration with the host's current version" do
      invoke!
      expect(bodies).to all(include('ActiveRecord::Migration[ActiveRecord::Migration.current_version]'))
    end

    it 'writes Rails migration methods and no SQL statement' do
      invoke!
      expect(bodies.join).not_to match(/\bexecute\b|CREATE |DROP /)
    end

    it 'names every table kiosk_*, in public by default' do
      invoke!
      tables = bodies.join.scan(/create_table (\S+),/).flatten
      expect(tables).to all(match(/\A:kiosk_[a-z_]+\z/))
    end

    it 'puts every table in a schema of its own when one is given, and creates the schema' do
      invoke!(%w[--schema=ksk])
      tables = bodies.join.scan(/create_table (\S+),/).flatten
      expect(tables).to all(match(/\A"ksk\.kiosk_[a-z_]+"\z/))
      expect(bodies.first).to include('create_schema "ksk", if_not_exists: true')
    end

    it "references the operator's user table with the given id type" do
      invoke!(%w[--user-table=members --user-id-type=bigint])
      expect(bodies.join).to include('t.references :user, type: :bigint', 'to_table: :members')
      expect(bodies.join).not_to include(':uuid, null: false, foreign_key: { to_table: :members')
    end
  end

  # The generated migrations, run up and down against Postgres, for each id type.
  describe 'migrations against Postgres' do
    include_context 'with a freshly generated host app'

    let(:conn) { ActiveRecord::Base.connection }
    let(:migration_classes) do
      migrations.sort.map do |path|
        mod = Module.new.tap { load(path, it) }
        mod.const_get(mod.constants.fetch(0))
      end
    end

    before do
      skip "no local Postgres reachable (#{SpecPostgres.error})" if SpecPostgres.error
      conn.execute('DROP SCHEMA IF EXISTS ksk CASCADE')
    end

    after do
      next if SpecPostgres.error

      conn.execute('DROP SCHEMA IF EXISTS ksk CASCADE')
      conn.execute('DROP TABLE IF EXISTS spec_people CASCADE')
    end

    def tables = conn.select_values("SELECT schemaname || '.' || tablename FROM pg_tables WHERE schemaname = 'ksk'")

    def migrate(direction)
      list = direction == :up ? migration_classes : migration_classes.reverse
      ActiveRecord::Migration.suppress_messages { list.each { it.migrate(direction) } }
    end

    %w[uuid bigint integer text].each do |type|
      it "creates the fourteen tables for #{type} user ids and drops them all" do
        conn.execute("DROP TABLE IF EXISTS spec_people CASCADE; CREATE TABLE spec_people (id #{type} PRIMARY KEY)")
        invoke!(%W[--schema=ksk --user-table=spec_people --user-id-type=#{type}])
        migrate(:up)
        expect(tables.size).to eq(14)
        expect(tables).to all(start_with('ksk.kiosk_'))
        migrate(:down)
        expect(tables).to be_empty
      end
    end

    it 'keeps a KYC grant as a row keyed on the person, with no value column' do
      conn.execute('DROP TABLE IF EXISTS spec_people CASCADE; CREATE TABLE spec_people (id text PRIMARY KEY)')
      invoke!(%w[--schema=ksk --user-table=spec_people --user-id-type=text])
      migrate(:up)
      expect(conn.columns('ksk.kiosk_kyc_attributes').map(&:name)).to eq(%w[user_id name granted_at])
      expect(conn.primary_keys('ksk.kiosk_kyc_attributes')).to eq(%w[user_id name])
    end
  end
end
