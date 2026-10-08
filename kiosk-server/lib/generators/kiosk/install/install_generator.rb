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
    #   - config/routes/kiosk.rb                 — the engine mount, plus the
    #     section the operator's own per-verb routes go in
    #   - `draw(:kiosk)` in config/routes.rb     — what reaches that file
    #   - db/migrate/<ts>_create_kiosk_schema.rb — schema + helper functions
    #   - db/migrate/<ts+1>_create_kiosk_identity_tables.rb
    #   - db/migrate/<ts+2>_create_kiosk_reservations.rb
    #   - db/migrate/<ts+3>_create_kiosk_device_authorizations.rb
    #   - db/migrate/<ts+4>_create_kiosk_mandates.rb
    #   - db/migrate/<ts+5>_create_kiosk_kyc_attributes.rb
    #   - db/migrate/<ts+6>_create_kiosk_events.rb
    #
    # Every migration is a `create`: each table is created in its final shape,
    # so a fresh adopter installs the schema outright.
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
    class InstallGenerator < ::Rails::Generators::Base
      include ::Rails::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Generate the Kiosk initializer and its canonical base migrations." \
           " Draws the engine mount, so the origin answers on the wire."

      class_option :user_table,    type: :string, default: "users",
                                   desc: "Provider's user table name"
      class_option :user_id_type,  type: :string, default: "uuid",
                                   desc: "User-id column type: uuid | bigint | integer | text"
      class_option :schema,        type: :string, default: "kiosk",
                                   desc: "Postgres schema name for Kiosk helpers and tables"
      class_option :guc_namespace, type: :string, default: "app",
                                   desc: "GUC namespace prefix used in the session GUC names"

      # Rails::Generators::Migration requires a class-level
      # next_migration_number. We bump a counter so the migrations
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

      # The mount is what makes the gem a wire: bundling kiosk-server draws no
      # route at all, so an app that installs without these two steps serves
      # nothing — not even the discovery document an assistant reads first.
      def create_wire_routes
        template "routes_kiosk.rb.tt", "config/routes/kiosk.rb"
      end

      def draw_wire_routes
        route "draw(:kiosk)"
      end

      def create_schema_migration
        migration_template "create_kiosk_schema.rb.tt",
                           "db/migrate/create_kiosk_schema.rb"
      end

      def create_identity_tables_migration
        migration_template "create_kiosk_identity_tables.rb.tt",
                           "db/migrate/create_kiosk_identity_tables.rb"
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

      def create_kyc_attributes_migration
        migration_template "create_kiosk_kyc_attributes.rb.tt",
                           "db/migrate/create_kiosk_kyc_attributes.rb"
      end

      def create_events_migration
        migration_template "create_kiosk_events.rb.tt",
                           "db/migrate/create_kiosk_events.rb"
      end
    end
  end
end
