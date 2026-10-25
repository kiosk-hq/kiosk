# frozen_string_literal: true

require 'rails/generators'
require 'rails/generators/active_record'

module Kiosk
  module PayStripe
    module Generators
      # `bin/rails g kiosk:pay_stripe:install`: writes the migration that creates
      # the `kiosk_stripe_customers` table, with its DDL written into the file.
      # {Kiosk::PaymentProviders::Stripe::CustomerRecord} reads and writes that table.
      class InstallGenerator < ::Rails::Generators::Base
        include ::Rails::Generators::Migration

        source_root File.expand_path('templates', __dir__)

        desc 'Generate the migration for the kiosk_stripe_customers table of kiosk-pay-stripe.'

        class_option :user_id_type, type: :string, default: 'uuid', enum: %w[uuid bigint integer text],
                                    desc: 'User-id column type: give the same type as to kiosk:install'

        def self.next_migration_number(dirname) = ::ActiveRecord::Generators::Base.next_migration_number(dirname)

        def create_stripe_customers_migration
          migration_template 'create_kiosk_pay_stripe_customers.rb.tt',
                             'db/migrate/create_kiosk_pay_stripe_customers.rb'
        end
      end
    end
  end
end
