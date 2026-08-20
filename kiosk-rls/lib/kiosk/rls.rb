# frozen_string_literal: true

# kiosk-rls — the Kiosk RLS DSL and SQL emitter.
# See https://kiosk.tech.

require "kiosk"

require "kiosk/rls/version"
require "kiosk/rls/configuration_extension"
require "kiosk/rls/policy"
require "kiosk/rls/table"
require "kiosk/rls/emitter"
require "kiosk/rls/dsl"

# In a Rails host the gem injects the migration verbs itself, through its own
# railtie (K-504) — the application writes no wiring. Outside Rails there is no
# `Rails::Railtie` to hang it on and nothing to inject into, so the require is
# guarded and the host includes {Kiosk::RLS::DSL} where it wants it.
require "kiosk/rls/railtie" if defined?(::Rails::Railtie)

module Kiosk
  module RLS
    # No top-level methods — the DSL lives in {Kiosk::RLS::DSL}.
    #
    # Rails hosts get it on `ActiveRecord::Migration` automatically via
    # {Kiosk::RLS::Railtie}. Any other host (a Sequel migration, a plain
    # script) mixes it in wherever it provides `#execute(sql)`:
    #
    #   class MyMigration
    #     include Kiosk::RLS::DSL
    #   end
  end
end
