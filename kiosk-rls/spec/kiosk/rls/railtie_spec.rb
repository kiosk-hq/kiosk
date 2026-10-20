# frozen_string_literal: true

# The railtie makes `enable_rls_on` callable from a host's migration with no
# wiring in the host. This needs real Rails: `railties` and `activerecord` are
# test-only Gemfile entries, never gemspec dependencies. When they are missing
# the spec fails; it does not skip.

begin
  require 'rails'
  require 'active_record'
rescue LoadError => e
  raise "kiosk-rls's railtie spec needs the test-only railties/activerecord " \
        "entries in the Gemfile — they are gone or unresolvable (#{e.message}). " \
        'Restore them; do not skip this spec.'
end

# spec_helper required "kiosk/rls" before Rails was loaded, so the guarded
# `require "kiosk/rls/railtie"` at the bottom of lib/kiosk/rls.rb did not run.
# Load the entry point again now that `Rails::Railtie` is defined, as it is in a
# Rails host when Bundler.require reaches this gem.
load File.expand_path('../../../lib/kiosk/rls.rb', __dir__)

module RailtieSpecSupport
  # A host migration that records the SQL it would execute.
  def self.recording_migration
    Class.new(ActiveRecord::Migration[ActiveRecord::Migration.current_version]) do
      attr_reader :statements

      def execute(sql)
        (@statements ||= []) << sql
      end
    end.new
  end
end

RSpec.describe Kiosk::RLS::Railtie do
  it 'is loaded by kiosk/rls once Rails::Railtie is defined' do
    expect(Kiosk::RLS.const_defined?(:Railtie)).to be(true)
  end

  it 'is a Rails::Railtie, so Rails runs it as part of the boot chain' do
    expect(described_class.ancestors).to include(Rails::Railtie)
  end

  it 'registers exactly one initializer, named for the gem' do
    names = described_class.instance.initializers.map(&:name)
    expect(names).to eq(['kiosk_rls.migration_dsl'])
  end

  context 'when the boot chain has run' do
    before do
      described_class.instance.initializers.each(&:run)
      # Loading the constant runs the :active_record load hooks the initializer subscribed to.
      ActiveRecord::Base
    end

    it 'puts the DSL on ActiveRecord::Migration with no wiring from the host' do
      expect(ActiveRecord::Migration.include?(Kiosk::RLS::DSL)).to be(true)
    end

    it 'makes all five migration verbs callable from a host migration class' do
      expect(RailtieSpecSupport.recording_migration).to respond_to(
        :enable_rls_on, :add_kiosk_policy_to, :change_kiosk_policy_on, :remove_kiosk_policy_from, :rename_kiosk_policy_on
      )
    end

    it "emits the RLS DDL through the migration's own #execute" do
      migration = RailtieSpecSupport.recording_migration
      migration.enable_rls_on :orders, app_role: 'app_role' do
        policy :select, using: 'user_id = kiosk.current_user_id()'
        comment 'Orders owned by the placing user.'
      end

      expect(migration.statements).to include(
        'ALTER TABLE "orders" ENABLE ROW LEVEL SECURITY',
        'ALTER TABLE "orders" FORCE ROW LEVEL SECURITY'
      )
    end
  end
end
