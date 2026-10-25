# frozen_string_literal: true

module Kiosk
  module Server
    # Each account's tolled calls since its last proof, in
    # `tolled_calls.calls_since_proof`. The count belongs to the account: the
    # assistants bound to one account share it, and a new access token or a
    # new key does not set it back.
    module TolledCalls
      module_function

      # Adds this call and answers the account's count, this call included.
      # One statement, so calls made at the same time each get their own number.
      def count!(user_id)
        sql = <<~SQL.squish
          INSERT INTO "#{schema}".kiosk_tolled_calls AS t (user_id, calls_since_proof) VALUES ($1, 1)
          ON CONFLICT (user_id) DO UPDATE SET calls_since_proof = t.calls_since_proof + 1
          RETURNING calls_since_proof
        SQL
        connection.exec_query(sql, 'Kiosk tolled call', [user_id]).rows.dig(0, 0)
      end

      # A valid proof sets the count back to zero.
      def reset!(user_id)
        connection.exec_query(%(UPDATE "#{schema}".kiosk_tolled_calls SET calls_since_proof = 0 WHERE user_id = $1),
                              'Kiosk tolled calls reset', [user_id])
        nil
      end

      # A binding adds the previous account's count to the new account's, so a
      # binding never lowers the count of the calls an assistant made.
      def carry!(from:, to:)
        sql = <<~SQL.squish
          INSERT INTO "#{schema}".kiosk_tolled_calls AS t (user_id, calls_since_proof)
          SELECT $2, calls_since_proof FROM "#{schema}".kiosk_tolled_calls WHERE user_id = $1
          ON CONFLICT (user_id) DO UPDATE SET calls_since_proof = t.calls_since_proof + excluded.calls_since_proof
        SQL
        connection.exec_query(sql, 'Kiosk tolled calls carry', [from, to])
        nil
      end

      def connection = ::ActiveRecord::Base.lease_connection
      def schema = Kiosk.configuration.schema
    end
  end
end
