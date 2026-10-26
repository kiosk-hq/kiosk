# frozen_string_literal: true

require 'active_record'
require 'kiosk/test_helpers/in_process_executor'

# The README's "## Example" block, run as written against Postgres: an
# `orders` table whose policy shows a customer only their own rows, and
# `c.enforce_db_role`, so each identity scope runs as `c.app_role`.
module ReadmeExample
  SCHEMA = 'kiosk_rls_rspec_readme'
  ROLE   = 'kiosk_rls_rspec_readme_app'

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
  end

  def self.create_tables(db)
    db.execute(SETUP_SQL)
    db.execute("SET search_path TO #{SCHEMA}")
  end

  def self.drop_tables(db)
    db.execute("DROP SCHEMA IF EXISTS #{SCHEMA} CASCADE; DROP ROLE IF EXISTS #{ROLE}; SET search_path TO DEFAULT")
  end
end

class User < ActiveRecord::Base; end

RSpec.shared_context 'with the README database' do
  before do
    skip "no local Postgres reachable (#{ReadmeExample.postgres_error})" if ReadmeExample.postgres_error
    Kiosk.configure do |c|
      c.app_role        = ReadmeExample::ROLE
      c.enforce_db_role = true
    end
    Kiosk::TestHelpers.executor = Kiosk::TestHelpers::InProcessExecutor.new
    ActiveRecord::Base.connection.execute('TRUNCATE users, orders')
  end
end

RSpec.configure do |config|
  config.include_context 'with the README database', readme_database: true
  config.after(:suite) { ReadmeExample.drop_tables(ActiveRecord::Base.connection) if ReadmeExample.postgres_error.nil? }
end

eval(ReadmeExample.source.sub('type: :kiosk_journey do', 'type: :kiosk_journey, readme_database: true do'), # rubocop:disable Security/Eval -- runs the README's own example
     binding, 'README.md')

# The DSL block of the kiosk-test-support README, on the same database.
RSpec.describe Kiosk::TestHelpers::Journey, :readme_database, type: :kiosk_journey do
  let(:alice) { User.create!(email: 'alice@example.com') }
  let(:bob)   { User.create!(email: 'bob@example.com') }

  it 'runs the DSL block of the kiosk-test-support README as written' do # rubocop:disable RSpec/NoExpectationExample -- the expectations are in the README block
    readme = File.read(File.expand_path('../../../kiosk-test-support/README.md', __dir__))
    eval(readme[/^## DSL\n.*?^```ruby\n(.*?)^```/m, 1], binding, 'kiosk-test-support/README.md') # rubocop:disable Security/Eval -- runs the README's own example
  end
end
