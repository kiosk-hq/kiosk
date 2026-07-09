# frozen_string_literal: true

require "rails/generators"
require "rails/generators/base"
require "rails/generators/migration"

module Kiosk
  module Generators
    # Bootstrap generator for a host Rails app adopting Kiosk.
    #
    # Invocation:
    #   bin/rails g kiosk:install
    #
    # Produces:
    #   - config/initializers/kiosk.rb           — Kiosk.configure block
    #   - db/migrate/<ts>_create_kiosk_schema.rb — schema + helper functions
    #   - db/migrate/<ts+1>_create_kiosk_identity_tables.rb
    #   - db/migrate/<ts+2>_create_kiosk_actions_log.rb
    #   - db/migrate/<ts+3>_create_kiosk_reservations.rb
    #   - db/migrate/<ts+4>_create_kiosk_device_authorizations.rb
    #   - db/migrate/<ts+5>_create_kiosk_mandates.rb
    #
    # Each migration file is a thin wrapper that calls into
    # {Kiosk::Server::SchemaDefinitions} at host-app runtime, so the SQL
    # is regenerated against the current `Kiosk.configuration` when
    # `bin/rails db:migrate` runs.
    #
    # Class-option flags map to the generator-time arguments passed into
    # the SchemaDefinitions methods (the migration files embed them
    # literally — config drift between generation time and migrate time
    # only matters for fields the operator deliberately overrides).
    #
    # See spec §9 and implementation-plan §3 (migrations 001-006).
    class InstallGenerator < ::Rails::Generators::Base
      include ::Rails::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Generate Kiosk initializer and the seven base migrations (001-007)."

      class_option :user_table,    type: :string, default: "users",
                                   desc: "Provider's user table name"
      class_option :user_id_type,  type: :string, default: "uuid",
                                   desc: "User-id column type: uuid | bigint | integer | text"
      class_option :schema,        type: :string, default: "kiosk",
                                   desc: "Postgres schema name for Kiosk helpers and tables"
      class_option :guc_namespace, type: :string, default: "app",
                                   desc: "GUC namespace prefix used in SET LOCAL statements"

      # Rails::Generators::Migration requires a class-level
      # next_migration_number. We bump a counter so the six migrations
      # created in one invocation get strictly-ascending UTC timestamps
      # (otherwise `db/migrate` glob sort is non-deterministic).
      @migration_counter = 0
      class << self
        def next_migration_number(_dirname)
          @migration_counter ||= 0
          number = Time.now.utc.strftime("%Y%m%d%H%M%S").to_i + @migration_counter
          @migration_counter += 1
          format("%014d", number)
        end
      end

      def create_initializer
        template "initializer.rb.tt", "config/initializers/kiosk.rb"
      end

      def create_schema_migration
        migration_template "create_kiosk_schema.rb.tt",
                           "db/migrate/create_kiosk_schema.rb"
      end

      def create_identity_tables_migration
        migration_template "create_kiosk_identity_tables.rb.tt",
                           "db/migrate/create_kiosk_identity_tables.rb"
      end

      def create_actions_log_migration
        migration_template "create_kiosk_actions_log.rb.tt",
                           "db/migrate/create_kiosk_actions_log.rb"
      end

      def create_reservations_migration
        migration_template "create_kiosk_reservations.rb.tt",
                           "db/migrate/create_kiosk_reservations.rb"
      end

      def create_device_authorizations_migration
        migration_template "create_kiosk_device_authorizations.rb.tt",
                           "db/migrate/create_kiosk_device_authorizations.rb"
      end

      def create_mandates_migration
        migration_template "create_kiosk_mandates.rb.tt",
                           "db/migrate/create_kiosk_mandates.rb"
      end

      def create_kyc_migration
        migration_template "add_kyc_verified_at_to_kiosk_agents.rb.tt",
                           "db/migrate/add_kyc_verified_at_to_kiosk_agents.rb"
      end
    end
  end
end
