# frozen_string_literal: true

module Kiosk
  module Server
    # The accounts that the engine opened for assistants at registration, in
    # `assistant_accounts`. The first binding of the assistant merges its
    # assistant account into the human's account: from then on the spend of
    # the human's account includes the settlements and visits of the assistant
    # account. Unlinking the assistant later keeps the merge.
    module AssistantAccounts
      module_function

      # Records `user_id` as the account of a new assistant. An account that
      # `assistant_creation` gave to an earlier key is recorded once.
      def record!(user_id)
        connection.exec_query(%(INSERT INTO "#{schema}".assistant_accounts (user_id) VALUES ($1) ON CONFLICT DO NOTHING),
                              'Kiosk assistant account', [user_id])
        nil
      end

      # Merges the account `from` into the account `into` when `from` is an
      # assistant account that is not merged yet. A binding moves an assistant
      # to the account of the approving human, which is never an assistant
      # account: so the account of one human never merges into the account of
      # another, and merges do not form chains.
      def merge!(from:, into:)
        connection.exec_query(<<~SQL.squish, 'Kiosk assistant account merge', [from, into])
          UPDATE "#{schema}".assistant_accounts SET merged_into = $2, merged_at = now()
          WHERE user_id = $1 AND merged_into IS NULL
        SQL
        nil
      end

      def connection = ::ActiveRecord::Base.lease_connection
      def schema = Kiosk.configuration.schema
    end
  end
end
