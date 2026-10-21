# frozen_string_literal: true

module Kiosk
  module Server
    # Puts a new key on a registered agent (spec Section 5.7). Both keys prove
    # possession, and the old key's proof names the new key, so the agent keeps
    # its id, account, role and reputation. Every earlier token is revoked.
    module AgentRotation
      NEW_KEY_HINT = 'the proof of your registered key carries `new_key`: the RFC 7638 thumbprint ' \
                     'of new_public_key, so the old key names the key that replaces it'

      module_function

      def call(public_key_pem:, signed:, new_public_key_pem:, new_signed:)
        pem     = public_key_pem.to_s.strip
        new_pem = new_public_key_pem.to_s.strip
        prove_both!(pem, signed, new_pem, new_signed)

        agent = AgentLogin.registered_agent(pem)
        refuse_known_key!(new_pem)
        replace_key(agent.fetch('id'), new_pem)
        role = AgentLogin.primary_role(agent.fetch('allowed_roles'))
        { access_token: AgentIdentityProviders::DefaultAgentIdp.new.issue(agent_id: agent.fetch('id'), role: role) }
      end

      # Both keys prove possession, and both challenges burn, before any lookup or state change.
      def prove_both!(pem, signed, new_pem, new_signed)
        proof     = PopVerifier.verify!(public_key_pem: pem, signed: signed)
        new_proof = PopVerifier.verify!(public_key_pem: new_pem, signed: new_signed)
        named = proof[:new_key] == SigningKey.from_pem(new_pem).kid
        raise Errors::Unauthenticated.new('the proof does not name the new key', hint: NEW_KEY_HINT) unless named

        AuthChallenge.consume!(public_key_pem: pem, nonce: proof.fetch(:nonce))
        AuthChallenge.consume!(public_key_pem: new_pem, nonce: new_proof.fetch(:nonce))
      end

      def refuse_known_key!(pem)
        return unless AgentLogin.registered_agent?(pem)

        raise Errors::Conflict.new('the new public key is registered already',
                                   hint: 'rotate to a key that this origin does not know')
      end

      # The key and the revocation watermark move together, so no token outlives
      # the old key. Next second: JWT `iat` is whole seconds and the check is
      # `iat < watermark`; the IdP dates the new token at the watermark.
      def replace_key(agent_id, pem)
        conn = ::ActiveRecord::Base.lease_connection
        conn.transaction do
          conn.exec_query(<<~SQL.squish, 'Kiosk agent key rotation', [pem, agent_id])
            UPDATE #{Kiosk.configuration.schema}.agents SET public_key = $1 WHERE id = $2
          SQL
          Kiosk.configuration.revocation_store.revoke_all(agent_id, at: Time.now.to_i + 1)
        end
      end
      private_class_method :prove_both!, :refuse_known_key!, :replace_key
    end
  end
end
