# frozen_string_literal: true

module Kiosk
  module Server
    # Existing-identity login: prove control of an ALREADY-registered public key
    # (via the PoP handshake) and mint a fresh access token.
    #
    # Unlike {AgentRegistration}, this creates no user and no agent row — it
    # serves a key the provider has already seen. A public key the provider does
    # NOT know is a 404 ("register first"), never a silent new account. Multiple
    # concurrent logins with the same key are fine: each mints an independent
    # short-lived token, and siblings are never invalidated (revocation is
    # explicit, via `/auth/revoke`).
    module AgentLogin
      module_function

      def call(public_key_pem:, signed:)
        config = Kiosk.configuration
        # `.to_s` first so a wrong-typed field (number/object/array from the JSON
        # body) yields a clean 400 downstream via PopVerifier's invalid-key guard,
        # not a NoMethodError 500 here.
        pem    = public_key_pem.to_s.strip

        # Prove possession BEFORE any lookup or state change.
        payload = PopVerifier.verify!(public_key_pem: pem, signed: signed)
        AuthChallenge.consume!(public_key_pem: pem, nonce: payload.fetch(:nonce))

        # `lease_connection`, not `connection` (K-782, following
        # `wire_controller.rb`): `ActiveRecord::Base.connection` is
        # soft-deprecated in Rails 8.1 and RAISES under
        # `permanent_connection_checkout = :disallowed`. This site is one
        # statement in no transaction, so `with_connection` would be correct
        # too — it takes the lease anyway, because a login runs inside a Rails
        # request that already holds one, and because an engine with two
        # connection idioms is what K-782 exists to close.
        #
        # The key is CALLER-SUPPLIED — it is the request body — so it is `$1`.
        conn = ::ActiveRecord::Base.lease_connection
        row  = conn.exec_query(<<~SQL, "Kiosk agent lookup by key", [pem]).to_a.first
          SELECT id, user_id, allowed_roles FROM #{config.schema}.agents
          WHERE public_key = $1 AND revoked_at IS NULL
          LIMIT 1
        SQL
        if row.nil?
          raise Errors::NotFound.new(
            "no agent registered for this public key",
            hint: "POST /auth/register to create an identity for a new key",
          )
        end

        agent_id = row.fetch("id")
        role     = primary_role(row.fetch("allowed_roles"))
        token    = AgentIdentityProviders::DefaultAgentIdp.new.issue(agent_id: agent_id, role: role)
        { access_token: token }
      end

      # `allowed_roles` comes back as a Postgres text[] literal ("{customer}")
      # or an Array depending on adapter casting. The token carries the agent's
      # registered role, not the server's registration_role default.
      def primary_role(allowed_roles)
        case allowed_roles
        when Array then allowed_roles.first
        else allowed_roles.to_s.delete("{}").split(",").first
        end
      end
      private_class_method :primary_role
    end
  end
end
