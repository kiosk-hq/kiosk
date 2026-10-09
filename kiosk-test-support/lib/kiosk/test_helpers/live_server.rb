# frozen_string_literal: true

require "puma"
require "socket"
require "kiosk/test_helpers/assistant"

module Kiosk
  module TestHelpers
    # Tests whose writes must be committed: each starts from the seeds and
    # leaves the database empty.
    module SeededDatabase
      def self.included(base)
        base.use_transactional_tests = false
        base.setup do
          SeededDatabase.empty
          Rails.application.load_seed
        end
        base.teardown { SeededDatabase.empty }
      end

      def self.empty
        connection = ActiveRecord::Base.connection
        schemas = ActiveRecord.dump_schemas.split(",").map { connection.quote(_1.strip) }.join(", ")
        tables = connection.select_values(<<~SQL)
          SELECT format('%I.%I', schemaname, tablename) FROM pg_tables
          WHERE schemaname IN (#{schemas}) AND tablename NOT IN ('schema_migrations', 'ar_internal_metadata')
        SQL
        connection.execute("TRUNCATE #{tables.join(", ")} RESTART IDENTITY CASCADE") if tables.any?
      end
    end

    # Serves the app over HTTP from the test process, on a free port that
    # becomes the origin's issuer, so a test drives the wire as an assistant does.
    module LiveServer
      def self.included(base)
        base.include SeededDatabase
      end

      def self.url
        @url ||= begin
          port   = TCPServer.open("127.0.0.1", 0) { |socket| socket.addr[1] }
          server = Puma::Server.new(Rails.application, nil, min_threads: 0, max_threads: 8)
          server.add_tcp_listener("127.0.0.1", port)
          server.run
          Kiosk.configuration.issuer = "http://127.0.0.1:#{port}"
        end
      end

      def live_url = LiveServer.url

      def assistant = @assistant ||= Assistant.new(base_url: live_url)

      def register = assistant.register!
    end
  end
end
