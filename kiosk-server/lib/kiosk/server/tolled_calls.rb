# frozen_string_literal: true

module Kiosk
  module Server
    # Each assistant's tolled calls since its last paid proof, in
    # `agents.calls_since_proof`. The count belongs to the assistant, so a new
    # access token does not set it back.
    module TolledCalls
      module_function

      # Adds this call and answers the count, this call included; nil for a
      # caller with no assistant row. One statement, so calls made at the same
      # time each get their own number.
      def count!(agent_id)
        return if agent_id.nil?

        sql = %(UPDATE "#{schema}".agents SET calls_since_proof = calls_since_proof + 1 WHERE id = $1 RETURNING calls_since_proof)
        connection.exec_query(sql, 'Kiosk tolled call', [agent_id]).rows.dig(0, 0)
      end

      # A paid proof sets the count back to zero.
      def reset!(agent_id)
        connection.exec_query(%(UPDATE "#{schema}".agents SET calls_since_proof = 0 WHERE id = $1), 'Kiosk tolled calls reset', [agent_id])
        nil
      end

      def connection = ::ActiveRecord::Base.lease_connection
      def schema = Kiosk.configuration.schema
    end
  end
end
