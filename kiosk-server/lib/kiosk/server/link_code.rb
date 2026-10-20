# frozen_string_literal: true

module Kiosk
  module Server
    # Account binding started by the human: the signed-in holder mints a
    # single-use link code ({.mint}, POST /auth/link) and their assistant
    # redeems it with its key, a possession proof and the auth toll ({.redeem}, POST /auth/claim).
    module LinkCode
      CLIENT_ID = 'kiosk-link'

      module_function

      # Born `:approved`: the human is the approval. `requested_role:` is the
      # minting human's own role, never anything the assistant sends.
      def mint(user_id:,
               requested_role: nil,
               store: Kiosk.configuration.device_authorization_store,
               expires_in: DeviceAuthorization::DEFAULT_EXPIRES_IN,
               now: Time.current)
        plain_device_code, _plain_user_code, da = DeviceAuthorization.generate(
          client_id: CLIENT_ID,
          kind: :link,
          requested_role: requested_role,
          expires_in: expires_in,
          now: now
        )
        da = da.approve(user_id: user_id)
        store.create(da)

        { link_code: plain_device_code, expires_in: expires_in, da: da }
      end

      # The toll comes before the lookup, so an unknown code costs the same work as a live one.
      def redeem(code:, public_key_pem:, signed:, pow: nil, # rubocop:disable Metrics/ParameterLists -- the claim controller and the specs pass these by name
                 store: Kiosk.configuration.device_authorization_store,
                 now: Time.current)
        raise Errors::BadRequest, 'code required' if code.to_s.empty?

        pem = public_key_pem.to_s.strip
        PopVerifier.load_public_key(pem)
        AuthToll.gate(verb: 'auth/claim', body: { code: code.to_s, public_key: pem }, pow: pow)
        da = live_link(store, code.to_s, now)

        # The proof comes before the consume, so a failed one leaves the code live.
        prove_possession!(pem, signed)
        # The atomic consume, not `consumed?` below, decides single use under a race.
        raise Errors::Conflict, 'link code already used' if store.claim_consume(da, now: now).nil?

        bind(pem, da)
      end

      class << self
        private

        def prove_possession!(pem, signed)
          payload = PopVerifier.verify!(public_key_pem: pem, signed: signed)
          AuthChallenge.consume!(public_key_pem: pem, nonce: payload.fetch(:nonce))
        end

        def bind(pem, link)
          result = AccountBinding.bind!(public_key_pem: pem, user_id: link.user_id, requested_role: link.requested_role)
          { agent_id: result[:agent_id], user_id: result[:user_id], access_token: result[:access_token] }
        end

        def live_link(store, code, now)
          da = store.lookup_by_device_code_hash(DeviceAuthorization.hash_device_code(code))
          unless da&.link?
            raise Errors::NotFound.new(
              'unknown link code',
              hint: 'the account holder mints one at POST /auth/link (link codes are single-use and short-lived)'
            )
          end
          raise Errors::Conflict, 'link code already used' if da.consumed?

          expire_if_due(store, da, now)
        end

        def expire_if_due(store, link, now)
          if link.expired_at_time?(now) && link.approved?
            store.update(link.expire)
            raise Errors::NotFound, 'link code expired'
          end
          raise Errors::NotFound, 'link code expired' if link.expired?

          link
        end
      end
    end
  end
end
