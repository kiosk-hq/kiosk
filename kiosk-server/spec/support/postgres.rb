# frozen_string_literal: true

require 'active_record'

# Connects ActiveRecord to the Postgres that the PG* variables name.
# A spec skips when no server answers, so a machine without Postgres stays green.
module SpecPostgres
  # The connection error as text, or nil when the server answers.
  def self.error
    return @error if defined?(@error)

    @error = connect
  end

  def self.config
    {
      adapter: 'postgresql',
      host: ENV.fetch('PGHOST', nil),
      username: ENV.fetch('PGUSER', nil),
      password: ENV.fetch('PGPASSWORD', nil),
      database: ENV.fetch('PGDATABASE', 'postgres')
    }
  end

  def self.connect
    ActiveRecord::Base.establish_connection(config)
    ActiveRecord::Base.connection.execute('SELECT 1')
    nil
  rescue StandardError => e
    "#{e.class}: #{e.message}"
  end

  def self.recreate_schema(name)
    conn = ActiveRecord::Base.connection
    conn.execute(%(DROP SCHEMA IF EXISTS "#{name}" CASCADE))
    conn.execute(%(CREATE SCHEMA "#{name}"))
  end

  def self.drop_schema(name)
    ActiveRecord::Base.connection.execute(%(DROP SCHEMA IF EXISTS "#{name}" CASCADE)) unless error
  end
end
