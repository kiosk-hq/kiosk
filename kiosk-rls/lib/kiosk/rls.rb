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

module Kiosk
  module RLS
    # No top-level methods yet — the DSL lives in {Kiosk::RLS::DSL} and is
    # mixed into the host (typically `ActiveRecord::Migration`).
    #
    # For Rails users, `require "kiosk/rls/migration"` (not yet shipped)
    # will auto-inject. Until then, include manually:
    #
    #   ActiveRecord::Migration.include(Kiosk::RLS::DSL)
  end
end
