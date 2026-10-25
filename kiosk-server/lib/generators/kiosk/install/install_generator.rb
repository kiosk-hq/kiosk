# frozen_string_literal: true

require 'rails/generators'
require 'rails/generators/base'
require 'rails/generators/migration'

module Kiosk
  module Generators
    # `bin/rails g kiosk:install`: writes the Kiosk initializer, the Kiosk routes
    # and the migrations of Kiosk's `kiosk_*` tables.
    class InstallGenerator < ::Rails::Generators::Base
      include ::Rails::Generators::Migration

      source_root File.expand_path('templates', __dir__)

      desc 'Generate the Kiosk initializer and its canonical base migrations. ' \
           'Draws the engine mount, so the origin answers Kiosk requests.'

      class_option :user_table,    type: :string, default: 'users',
                                   desc: "Provider's user table name"
      class_option :user_id_type,  type: :string, default: 'uuid', enum: %w[uuid bigint integer text],
                                   desc: 'User-id column type: uuid | bigint | integer | text'
      class_option :schema,        type: :string, default: 'public',
                                   desc: "Postgres schema of Kiosk's tables"

      # Ascending timestamps within one run, so the migrations sort in order.
      @migration_counter = 0
      class << self
        def next_migration_number(_dirname)
          @migration_counter ||= 0
          number = Time.now.utc.strftime('%Y%m%d%H%M%S').to_i + @migration_counter
          @migration_counter += 1
          format('%014d', number)
        end
      end

      MIGRATIONS = %w[identity_tables device_authorizations mandates kyc_attributes events
                      pow_spent revocations visits refunds].freeze

      no_commands do
        def public_schema? = options[:schema] == 'public'

        # A Kiosk table as a migration names it: `:kiosk_agents`, or `"ops.kiosk_agents"`.
        def table(name) = public_schema? ? ":kiosk_#{name}" : %("#{options[:schema]}.kiosk_#{name}")

        # The type of `users.id`, which every `user_id` column takes.
        def user_id_type = ":#{options[:user_id_type]}"

        # The foreign key of a `user_id` column: a row goes with its user.
        def users_key = "{ to_table: :#{options[:user_table]}, on_delete: :cascade }"
      end

      def create_initializer
        template 'initializer.rb.tt', 'config/initializers/kiosk.rb'
      end

      # schema.rb dumps only the search path's schemas unless told otherwise.
      def dump_kiosk_schema
        return if public_schema?

        application %(config.active_record.dump_schemas = "public,#{options[:schema]}")
      end

      # The engine mount, and a place for the operator's verbs under it.
      def draw_wire_routes
        route <<~RUBY
          kiosk do
            # queries :catalog
            # actions :place_order
          end
        RUBY
      end

      def create_migrations
        MIGRATIONS.each do |name|
          migration_template "create_kiosk_#{name}.rb.tt", "db/migrate/create_kiosk_#{name}.rb"
        end
      end
    end
  end
end
