# frozen_string_literal: true

require 'stringio'
require 'tmpdir'
require 'fileutils'
require 'rails/generators'
require_relative '../../lib/generators/kiosk/install/install_generator'

# The migrations `kiosk:install` writes, generated into a scratch app and run
# against the spec database, so a spec reads and writes the tables an operator gets.
module KioskTables
  module_function

  # Runs the named migrations (`:identity_tables`, `:mandates`, …) in order,
  # with their tables in `schema`.
  def create(*names, schema:, user_table: 'users', user_id_type: 'uuid')
    args = ["--schema=#{schema}", "--user-table=#{user_table}", "--user-id-type=#{user_id_type}"]
    in_scratch_app(args) do |dir|
      names.each do |name|
        path = Dir[File.join(dir, "db/migrate/*_create_kiosk_#{name}.rb")].fetch(0)
        migration = Module.new.tap { load(path, it) }.const_get("CreateKiosk#{name.to_s.camelize}")
        ActiveRecord::Migration.suppress_messages { migration.migrate(:up) }
      end
    end
  end

  # Runs the generator into a scratch app and yields the app's directory.
  def in_scratch_app(args)
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'config'))
      File.write(File.join(dir, 'config/routes.rb'), "Rails.application.routes.draw do\nend\n")
      File.write(File.join(dir, 'config/application.rb'), "class Application < Rails::Application\nend\n")
      quietly { Kiosk::Generators::InstallGenerator.start(args, destination_root: dir) }
      yield dir
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
