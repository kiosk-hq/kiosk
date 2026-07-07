# frozen_string_literal: true

module Kiosk
  module Server
    # Greenfield self-registration: provision an id-only synthetic principal
    # and an agent bound to it, then mint the agent's first token. No human.
    module AgentRegistration
      module_function

      def call(public_key_pem:, signed:, pow: nil)
        config     = Kiosk.configuration
        role       = config.registration_role.to_s
        difficulty = config.registration_difficulty

        # Normalise PEM: strip leading/trailing whitespace so lookup matches storage.
        public_key_pem = public_key_pem.strip

        # The role is pinned server-side — the agent never sends one. A missing
        # or misconfigured registration_role is a provider error (loud 500),
        # NOT a client BadRequest.
        if role.empty?
          raise Errors::ConfigurationError,
                "Kiosk.configuration.registration_role is not set. Self-registration " \
                "mints a token with no human in the loop, so the provider MUST pin the " \
                "role server-side (agents cannot choose it). " \
                "Set: Kiosk.configure { |c| c.registration_role = :customer }"
        end
        unless config.roles.map(&:to_s).include?(role)
          raise Errors::ConfigurationError,
                "registration_role #{role.inspect} is not among configured roles " \
                "#{config.roles.inspect}"
        end

        if difficulty > 0
          unless pow && ProofOfWork.valid?(public_key_pem: public_key_pem, pow: pow, difficulty: difficulty)
            raise Errors::BadRequest.new(
              "proof-of-work required or invalid",
              hint: "Compute SHA256(public_key_pem + '.' + pow) with >= #{difficulty} leading zero bits",
            )
          end
        end

        # Prove the registrant controls the PRIVATE half of the key it is
        # registering — a public key alone is not a credential (it is public).
        # Origin-bound + single-use, so it can't be relayed or replayed.
        payload = PopVerifier.verify!(public_key_pem: public_key_pem, signed: signed)
        AuthChallenge.consume!(public_key_pem: public_key_pem, nonce: payload.fetch(:nonce))

        conn = ActiveRecord::Base.connection

        # A known public key is NOT re-registered — that would be a second way to
        # mint an identity for an existing key (and the old idempotent re-issue
        # blurred register vs. login). Existing keys refresh their token through
        # POST /auth/login instead.
        existing = conn.execute(<<~SQL).first
          SELECT id FROM #{config.schema}.agents
          WHERE public_key = #{conn.quote(public_key_pem)} AND revoked_at IS NULL
          LIMIT 1
        SQL
        if existing
          raise Errors::Conflict.new(
            "public key already registered",
            hint: "use POST /auth/login to refresh a token for an existing key",
          )
        end

        conn.transaction do
          user_id  = config.user_model.constantize.create!.id
          agent_id = conn.execute(<<~SQL).first.fetch("id")
            INSERT INTO #{config.schema}.agents (user_id, allowed_roles, public_key)
            VALUES (#{conn.quote(user_id)},
                    ARRAY[#{conn.quote(role)}]::text[], #{conn.quote(public_key_pem)})
            RETURNING id
          SQL
          token = AgentIdentityProviders::DefaultAgentIdp.new.issue(agent_id: agent_id, role: role)
          { agent_id: agent_id, user_id: user_id.to_s, access_token: token }
        end
      end
    end
  end
end
