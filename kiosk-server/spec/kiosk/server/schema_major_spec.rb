# frozen_string_literal: true

require "spec_helper"

# The no-skip rule, in two halves: the CONDITION on the engine class, and the
# READER that hands it the number out of the database. The condition lives on
# the class rather than inside `after_initialize` for the reason its three
# siblings there give — a block body is reachable only by booting a real
# application, and a control whose condition cannot be unit-tested is a control
# nobody can prove fires.
RSpec.describe Kiosk::Server::Engine, "the schema major" do
  describe ".schema_major_error" do
    def error(schema_major:, gem_major:)
      described_class.schema_major_error(schema_major: schema_major, gem_major: gem_major)
    end

    it "is silent when the gem installs the major the database carries" do
      expect(error(schema_major: 1, gem_major: 1)).to be_nil
    end

    # `db:migrate` runs inside a booted application, so the upgrade itself is a
    # boot with the gem one major ahead. Refusing it would make the upgrade
    # unreachable.
    it "is silent one major ahead — that boot IS the upgrade" do
      expect(error(schema_major: 1, gem_major: 2)).to be_nil
    end

    it "is silent when the gem is behind, so a deploy rollback still boots" do
      expect(error(schema_major: 2, gem_major: 1)).to be_nil
    end

    it "refuses two majors ahead" do
      expect(error(schema_major: 1, gem_major: 3)).to include("major 1")
    end

    it "refuses any wider jump" do
      expect(error(schema_major: 1, gem_major: 7)).to include("major 1")
    end

    it "names the major the operator has to install next" do
      expect(error(schema_major: 1, gem_major: 3)).to include("pin kiosk-server to major 2")
    end

    it "names the command that closes the gap" do
      expect(error(schema_major: 1, gem_major: 3)).to include("bin/rails db:migrate")
    end

    it "says the intermediate migrations are absent, not merely that the jump is wrong" do
      expect(error(schema_major: 1, gem_major: 3)).to include("not in this gem")
    end

    # A database provisioned before the marker shipped answers nothing about
    # its major, and an absent answer is not evidence of a skip.
    it "is silent when no major is recorded" do
      expect(error(schema_major: nil, gem_major: 9)).to be_nil
    end
  end

  # The reader, against a real Postgres: a throwaway schema built from the
  # shipped SQL, dropped afterwards. Connection comes from PG* env vars (CI's
  # service) or the local default socket; no reachable server → skip, never
  # fail, so DB-less machines stay green. Same shape as pow_spent_stores_spec.
  describe ".recorded_schema_major" do
    MARKER_SPEC_SCHEMA = "kiosk_schema_major_spec"
    BARE_SPEC_SCHEMA   = "kiosk_schema_major_spec_bare"

    def self.postgres_error
      @postgres_error ||= begin
        ::ActiveRecord::Base.establish_connection(
          adapter:  "postgresql",
          host:     ENV["PGHOST"],
          username: ENV["PGUSER"],
          password: ENV["PGPASSWORD"],
          database: ENV.fetch("PGDATABASE", "postgres"),
        )
        ::ActiveRecord::Base.connection.execute("SELECT 1")
        [false]
      rescue StandardError => e
        ["#{e.class}: #{e.message}"]
      end
      @postgres_error.first
    end

    before(:context) do
      skip "no local Postgres reachable (#{self.class.postgres_error})" if self.class.postgres_error

      conn = ::ActiveRecord::Base.connection
      [MARKER_SPEC_SCHEMA, BARE_SPEC_SCHEMA].each do |name|
        conn.execute(%(DROP SCHEMA IF EXISTS "#{name}" CASCADE))
      end
      conn.execute(%(CREATE SCHEMA "#{MARKER_SPEC_SCHEMA}"))
      conn.execute(Kiosk::Server::SchemaDefinitions.schema_major_sql(schema: MARKER_SPEC_SCHEMA, major: 4))
      conn.execute(%(CREATE SCHEMA "#{BARE_SPEC_SCHEMA}"))
    end

    after(:context) do
      next if self.class.postgres_error

      conn = ::ActiveRecord::Base.connection
      [MARKER_SPEC_SCHEMA, BARE_SPEC_SCHEMA].each do |name|
        conn.execute(%(DROP SCHEMA IF EXISTS "#{name}" CASCADE))
      end
    end

    it "reads the major the shipped SQL recorded" do
      expect(described_class.recorded_schema_major(schema: MARKER_SPEC_SCHEMA)).to eq(4)
    end

    it "answers nil for a kiosk schema laid down before the marker existed" do
      expect(described_class.recorded_schema_major(schema: BARE_SPEC_SCHEMA)).to be_nil
    end

    it "answers nil when there is no such schema at all" do
      expect(described_class.recorded_schema_major(schema: "kiosk_schema_major_spec_absent")).to be_nil
    end
  end
end
