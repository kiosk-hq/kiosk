# frozen_string_literal: true

require "kiosk/rls/dsl"

module Kiosk
  module RLS
    # Adds the five RLS migration verbs to `ActiveRecord::Migration` in a Rails
    # host, so a migration can call `enable_rls_on :orders do … end` with no
    # wiring in the application at all.
    #
    # WHY THIS EXISTS (K-504). Until 2026-08-21 the gem shipped no injection
    # point, and its README taught the host to write
    #
    #   ActiveRecord::Migration.include(Kiosk::RLS::DSL)
    #
    # in `config/initializers/`. That is an application monkey-patching a
    # FRAMEWORK class on a gem's behalf: the host carries the line, the host
    # gets the load-order bug when the line moves, and four demos plus the
    # README carried four hand-copied variants of it. A railtie is the same
    # extension made by the party that owns it — the gem extends the framework
    # it declares a dependency on, which is what `Rails::Railtie` is for and
    # what every other DDL-verb gem does (scenic's `create_view`, fx's
    # `create_function`).
    #
    # `ActiveSupport.on_load(:active_record)` rather than a bare `include`:
    # ActiveRecord is lazily loaded, so touching `ActiveRecord::Migration` at
    # railtie-definition time would force the whole framework up during boot.
    # The hook fires when `ActiveRecord::Base` is first loaded — and fires
    # immediately if that already happened.
    #
    # NOT loaded outside Rails. `kiosk-rls` has no Rails runtime dependency by
    # design (it is a pure SQL generator; the host provides `#execute`), so
    # `lib/kiosk/rls.rb` requires this file only when `Rails::Railtie` is
    # defined. A non-Rails host still includes {Kiosk::RLS::DSL} itself, which
    # is the documented path for Sequel migrations and for plain scripts.
    class Railtie < ::Rails::Railtie
      initializer "kiosk_rls.migration_dsl" do
        ActiveSupport.on_load(:active_record) do
          ActiveRecord::Migration.include(Kiosk::RLS::DSL)
        end
      end
    end
  end
end
