# frozen_string_literal: true

require "rails/generators"
require "rails/generators/base"
require "rails/generators/migration"

module Kiosk
  module Generators
    # `bin/rails g kiosk:install`: writes the Kiosk initializer, the wire routes
    # and the migrations, which call {Kiosk::Server::SchemaDefinitions} at migrate time.
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

      # Ascending timestamps within one run, so the migrations sort in order.
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

      # schema.rb dumps only the search path's schemas unless told otherwise;
      # public goes first because the kiosk tables reference the user table.
      def dump_kiosk_schema
        application %(config.active_record.dump_schemas = "public,#{options[:schema]}")
      end

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

      def create_pow_spent_migration
        migration_template "create_kiosk_pow_spent.rb.tt",
                           "db/migrate/create_kiosk_pow_spent.rb"
      end
    end
  end
end
