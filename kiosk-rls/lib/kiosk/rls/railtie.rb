# frozen_string_literal: true

require "kiosk/rls/dsl"

module Kiosk
  module RLS
    # Adds the RLS migration verbs to `ActiveRecord::Migration` with no host wiring.
    class Railtie < ::Rails::Railtie
      initializer "kiosk_rls.migration_dsl" do
        ActiveSupport.on_load(:active_record) do
          ActiveRecord::Migration.include(Kiosk::RLS::DSL)
        end
      end
    end
  end
end
