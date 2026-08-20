# frozen_string_literal: true

# The railtie is what makes `enable_rls_on` callable from a host's migration
# with no wiring in the host at all (K-504). It replaced four hand-copied
# `ActiveRecord::Migration.include(Kiosk::RLS::DSL)` lines in demo
# initializers plus one in this gem's README, so what has to be pinned is not
# "the file exists" but "a real ActiveRecord::Migration ends up carrying the
# five verbs, because the gem put them there".
#
# That needs REAL Rails, which this gem does not depend on at runtime and must
# not start depending on. Both are true at once: `railties` and `activerecord`
# are test-only entries in the Gemfile, never in the gemspec, and the guard
# below fails loudly rather than skipping if they are missing — a spec that
# quietly skips when its subject is absent is the K-502 trap, and this is the
# only place the injection is proved inside the gem that owns it.

begin
  require "rails"
  require "active_record"
rescue LoadError => e
  raise "kiosk-rls's railtie spec needs the test-only railties/activerecord " \
        "entries in the Gemfile — they are gone or unresolvable (#{e.message}). " \
        "Restore them; do not skip this spec."
end

# spec_helper required "kiosk/rls" before Rails existed, so the guarded
# `require "kiosk/rls/railtie"` at the bottom of lib/kiosk/rls.rb did not fire.
# Re-`load` the entry point now that `Rails::Railtie` IS defined — which is the
# state a Rails host is in when Bundler.require reaches this gem, and which
# exercises the guard itself rather than requiring the railtie behind its back.
load File.expand_path("../../../lib/kiosk/rls.rb", __dir__)

RSpec.describe "Kiosk::RLS::Railtie" do
  it "is loaded by kiosk/rls once Rails::Railtie is defined" do
    expect(defined?(Kiosk::RLS::Railtie)).to eq("constant")
  end

  it "is a Rails::Railtie, so Rails runs it as part of the boot chain" do
    expect(Kiosk::RLS::Railtie.ancestors).to include(::Rails::Railtie)
  end

  it "registers exactly one initializer, named for the gem" do
    names = Kiosk::RLS::Railtie.instance.initializers.map(&:name)
    expect(names).to eq(["kiosk_rls.migration_dsl"])
  end

  context "after the boot chain has run" do
    before do
      Kiosk::RLS::Railtie.instance.initializers.each(&:run)
      # Fires ActiveSupport.run_load_hooks(:active_record, Base) — the hook the
      # initializer subscribed to. Referencing the constant is what loads it.
      ActiveRecord::Base
    end

    it "puts the DSL on ActiveRecord::Migration with no wiring from the host" do
      expect(ActiveRecord::Migration.include?(Kiosk::RLS::DSL)).to be(true)
    end

    it "makes all five migration verbs callable from a host migration class" do
      migration = Class.new(ActiveRecord::Migration[ActiveRecord::Migration.current_version])
      expect(migration.new).to respond_to(
        :enable_rls_on,
        :add_kiosk_policy_to,
        :change_kiosk_policy_on,
        :remove_kiosk_policy_from,
        :rename_kiosk_policy_on,
      )
    end

    it "emits the RLS DDL through the migration's own #execute" do
      migration = Class.new(ActiveRecord::Migration[ActiveRecord::Migration.current_version]) do
        attr_reader :statements

        def execute(sql)
          (@statements ||= []) << sql
        end
      end.new

      migration.enable_rls_on :orders, app_role: "app_role" do
        policy :select, using: "user_id = kiosk.current_user_id()"
        comment "Orders owned by the placing user."
      end

      expect(migration.statements).to include(
        'ALTER TABLE "orders" ENABLE ROW LEVEL SECURITY',
        'ALTER TABLE "orders" FORCE ROW LEVEL SECURITY',
      )
    end
  end
end
