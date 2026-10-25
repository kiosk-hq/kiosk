# frozen_string_literal: true

module Kiosk
  module Server
    # Puts a new key on a registered client (spec Section 5.7). The registered
    # key and the new key each sign a client assertion, and the assertion of
    # the registered key names the new key, so the client keeps its id,
    # account, role and reputation. Every earlier token is revoked.
    module AgentRotation
      NEW_KEY_HINT = 'the client assertion of your registered key carries `new_key`: the RFC 7638 ' \
                     'thumbprint of the key in jwks, so the registered key names the key that replaces it'

      SAME_CLIENT_HINT = 'sign both client assertions with your own client_id'

      module_function

      # @return [Client] the client with its new key
      # @raise [ClientAssertion::Refused, Errors::BadRequest, Errors::Conflict]
      def call(type:, assertion:, new_assertion:, jwks:)
        new_key = AssistantKey.from_jwks(jwks)
        client = prove_both!(type, assertion, new_assertion, new_key)
        refuse_known_key!(new_key)
        replace_key(client.id, AssistantKey.to_pem(new_key))
        Client.find(client.id)
      end

      # Both assertions are verified, then both are spent, before any change.
      def prove_both!(type, assertion, new_assertion, new_key)
        old = ClientAssertion.verify(type, assertion)
        new = ClientAssertion.verify(type, new_assertion, key: new_key)
        refuse!('the client assertion does not name the new key', NEW_KEY_HINT) unless old.claims['new_key'] == AssistantKey.thumbprint(new_key)
        refuse!('the two client assertions name two clients', SAME_CLIENT_HINT) unless new.client.id == old.client.id

        [old, new].each { ClientAssertion.spend!(it) }
        old.client
      end

      def refuse!(message, hint)
        raise ClientAssertion::Refused.new(message, hint: hint)
      end

      def refuse_known_key!(key)
        return unless Client.with_key(key)

        raise Errors::Conflict.new('the new key is registered already',
                                   hint: 'rotate to a key that this origin does not know')
      end

      # The key and the revocation watermark move together, so no token outlives the old key.
      def replace_key(agent_id, pem)
        conn = ::ActiveRecord::Base.lease_connection
        conn.transaction do
          conn.exec_query(<<~SQL.squish, 'Kiosk agent key rotation', [pem, agent_id])
            UPDATE #{Kiosk.configuration.schema}.kiosk_agents SET public_key = $1 WHERE id = $2
          SQL
          RevocationStores.revoke_issued(agent_id)
        end
      end
      private_class_method :prove_both!, :refuse!, :refuse_known_key!, :replace_key
    end
  end
end
