# frozen_string_literal: true

require 'test_helper'
require 'active_record'
require 'kiosk/test_helpers/in_process_executor'

# The README's "## Example" block, run as written against Postgres: an
# `orders` table whose policy shows a customer only their own rows, and
# `c.enforce_db_role`, so each identity scope runs as `c.app_role`.
module ReadmeExample
  SCHEMA = 'kiosk_rls_minitest_readme'
  ROLE   = 'kiosk_rls_minitest_readme_app'

  SETUP_SQL = <<~SQL.freeze
    DROP SCHEMA IF EXISTS #{SCHEMA} CASCADE;
    CREATE SCHEMA #{SCHEMA};
    DO $$ BEGIN CREATE ROLE #{ROLE} NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
    CREATE TABLE #{SCHEMA}.users (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), email text NOT NULL);
    CREATE TABLE #{SCHEMA}.orders (id bigserial PRIMARY KEY, user_id uuid NOT NULL, item text NOT NULL);
    ALTER TABLE #{SCHEMA}.orders ENABLE ROW LEVEL SECURITY;
    CREATE POLICY orders_owner ON #{SCHEMA}.orders
      USING (user_id = nullif(current_setting('app.current_user_id', true), '')::uuid);
    GRANT USAGE ON SCHEMA #{SCHEMA} TO #{ROLE};
    GRANT SELECT, INSERT ON #{SCHEMA}.orders TO #{ROLE};
    GRANT USAGE ON ALL SEQUENCES IN SCHEMA #{SCHEMA} TO #{ROLE};
  SQL

  def self.source
    readme = File.read(File.expand_path('../../README.md', __dir__))
    readme[/^## Example\n.*?^```ruby\n(.*?)^```/m, 1] or raise 'README.md has no ## Example ruby block'
  end

  # The connection error, or nil once a local Postgres answers and holds the tables.
  def self.postgres_error
    @postgres_error ||= begin
      connect_and_create
      [nil]
    rescue StandardError => e
      ["#{e.class}: #{e.message}"]
    end
    @postgres_error.first
  end

  def self.connect_and_create
    ActiveRecord::Base.establish_connection(
      adapter: 'postgresql', host: ENV.fetch('PGHOST', nil), username: ENV.fetch('PGUSER', nil),
      password: ENV.fetch('PGPASSWORD', nil), database: ENV.fetch('PGDATABASE', 'postgres')
    )
    create_tables(ActiveRecord::Base.connection)
    Minitest.after_run { drop_tables(ActiveRecord::Base.connection) }
  end

  def self.create_tables(db)
    db.execute(SETUP_SQL)
    db.execute("SET search_path TO #{SCHEMA}")
  end

  def self.drop_tables(db)
    db.execute("DROP SCHEMA IF EXISTS #{SCHEMA} CASCADE; DROP ROLE IF EXISTS #{ROLE}; SET search_path TO DEFAULT")
  end

  # Sits between the README's test class and Minitest::Test, so the README's
  # `super` in `setup` reaches it.
  module Database
    def setup
      skip "no local Postgres reachable (#{ReadmeExample.postgres_error})" if ReadmeExample.postgres_error
      super
      Kiosk.configure do |c|
        c.app_role        = ROLE
        c.enforce_db_role = true
      end
      Kiosk::TestHelpers.executor = Kiosk::TestHelpers::InProcessExecutor.new
      ActiveRecord::Base.connection.execute('TRUNCATE users, orders')
    end
  end
end

class User < ActiveRecord::Base; end

before = Minitest::Runnable.runnables.dup
eval(ReadmeExample.source, binding, 'README.md') # rubocop:disable Security/Eval -- runs the README's own example
(Minitest::Runnable.runnables - before).each { |test_class| test_class.include(ReadmeExample::Database) }
