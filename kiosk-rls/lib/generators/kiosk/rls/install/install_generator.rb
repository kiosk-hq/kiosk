# frozen_string_literal: true

require 'rails/generators'
require 'rails/generators/active_record'

module Kiosk
  module RLS
    module Generators
      # `bin/rails g kiosk:rls:install`: writes the migration that creates the
      # `kiosk_current_*()` functions a policy calls to read the request's principal.
      class InstallGenerator < ::Rails::Generators::Base
        include ::Rails::Generators::Migration

        source_root File.expand_path('templates', __dir__)

        desc 'Generate the migration for the kiosk_current_*() functions that RLS policies call.'

        class_option :user_id_type, type: :string, default: 'uuid', enum: %w[uuid bigint integer text],
                                    desc: 'User-id type: give the same type as to kiosk:install'
        class_option :guc_namespace, type: :string, default: Kiosk::GUC::DEFAULT_NAMESPACE,
                                     desc: 'The namespace of the session GUCs: give c.guc_namespace'

        def self.next_migration_number(dirname) = ::ActiveRecord::Generators::Base.next_migration_number(dirname)

        def create_functions_migration
          migration_template 'create_kiosk_rls_functions.rb.tt', 'db/migrate/create_kiosk_rls_functions.rb'
        end
      end
    end
  end
end
