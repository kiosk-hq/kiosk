# frozen_string_literal: true

module Kiosk
  module Server
    # Shared challenge store for a multi-process origin (§15.2):
    #
    #   Kiosk.configure do |c|
    #     c.auth_challenge_store = Kiosk::Server::AuthChallengeStores::ActiveRecord.new
    #   end
    module AuthChallengeStores
      # Backed by `<schema>.auth_challenges` ({SchemaDefinitions.auth_challenge_sql}),
      # which the operator adds when scaling past one process.
      class ActiveRecord
        # Seconds between expired-row sweeps; a sweep bounds growth, not correctness.
        DEFAULT_PRUNE_INTERVAL = 60

        def initialize(prune_interval: DEFAULT_PRUNE_INTERVAL)
          @prune_interval = prune_interval
          @last_prune_at  = 0
          @mutex          = Mutex.new
        end

        # Replaces any earlier challenge for the key.
        def put(public_key_pem, nonce, exp)
          return if public_key_pem.nil?

          prune_if_due!
          sql = <<~SQL
            INSERT INTO #{table} AS c (public_key, nonce, expires_at)
            VALUES ($1, $2, to_timestamp($3))
            ON CONFLICT (public_key) DO UPDATE
              SET nonce = EXCLUDED.nonce, expires_at = EXCLUDED.expires_at
          SQL
          connection.exec_query(sql, "Kiosk auth_challenge put", [public_key_pem, nonce, exp.to_i])
          nil
        end

        # One atomic DELETE, so two processes presenting one challenge get one `true`.
        def take(public_key_pem, nonce)
          return false if public_key_pem.nil? || nonce.nil?

          sql = <<~SQL
            DELETE FROM #{table}
            WHERE public_key = $1 AND nonce = $2 AND expires_at > now()
            RETURNING public_key
          SQL
          rows = connection.exec_query(
            sql, "Kiosk auth_challenge take", [public_key_pem, nonce]
          ).to_a
          !rows.empty?
        end

        def prune!
          connection.exec_query(%(DELETE FROM #{table} WHERE expires_at <= now()),
                                "Kiosk auth_challenge prune")
          nil
        end

        private

        def prune_if_due!
          now = Time.now.to_i
          due = @mutex.synchronize do
            if now - @last_prune_at >= @prune_interval
              @last_prune_at = now
              true
            else
              false
            end
          end
          prune! if due
        end

        def connection = ::ActiveRecord::Base.lease_connection
        def table = %("#{Kiosk.configuration.schema}".auth_challenges)
      end
    end
  end
end
