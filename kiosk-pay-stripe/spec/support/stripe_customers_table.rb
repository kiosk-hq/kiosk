# frozen_string_literal: true

require 'active_record'
require 'stringio'
require 'tmpdir'
require_relative '../../lib/generators/kiosk/pay_stripe/install/install_generator'

# The migration `kiosk:pay_stripe:install` writes, generated into a scratch
# directory and run against the in-memory database.
module StripeCustomersTable
  module_function

  # The generated migration file's text.
  def generate(*) = in_scratch_app(*) { File.read(it) }

  def migrate(direction, *)
    migration = in_scratch_app(*) do |path|
      Module.new.tap { load(path, it) }::CreateKioskPayStripeCustomers
    end
    ActiveRecord::Migration.suppress_messages { migration.migrate(direction) }
    Kiosk::PaymentProviders::Stripe::CustomerRecord.reset_column_information
  end

  # Runs the generator into a scratch directory and yields the migration it wrote.
  def in_scratch_app(*args)
    Dir.mktmpdir do |dir|
      quietly { Kiosk::PayStripe::Generators::InstallGenerator.start(args, destination_root: dir) }
      yield Dir[File.join(dir, 'db/migrate/*_create_kiosk_pay_stripe_customers.rb')].fetch(0)
    end
  end

  # Thor reports each file it writes on $stdout.
  def quietly
    stdout = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = stdout
  end
end
