# frozen_string_literal: true

module Kiosk
  module Server
    # Account binding started by the human: the signed-in holder mints a
    # single-use link code ({.mint}, POST /auth/link) and their assistant
    # redeems it with its key and a possession proof ({.redeem}, POST /auth/claim).
    module LinkCode
      CLIENT_ID = "kiosk-link"

      module_function

      # Born `:approved`: the human is the approval. `requested_role:` is the
      # minting human's own role, never anything the assistant sends.
      def mint(user_id:,
               requested_role: nil,
               store: Kiosk.configuration.device_authorization_store,
               expires_in: DeviceAuthorization::DEFAULT_EXPIRES_IN,
               now: Time.now)
        plain_device_code, _plain_user_code, da = DeviceAuthorization.generate(
          client_id:      CLIENT_ID,
          kind:           :link,
          requested_role: requested_role,
          expires_in:     expires_in,
          now:            now,
        )
        da = da.approve(user_id: user_id)
        store.create(da)

        { link_code: plain_device_code, expires_in: expires_in, da: da }
      end

      def redeem(code:, public_key_pem:, signed:,
                 store: Kiosk.configuration.device_authorization_store,
                 now: Time.now)
        raise Errors::BadRequest.new("code required") if code.nil? || code.to_s.empty?

        pem = public_key_pem.to_s.strip
        PopVerifier.load_public_key(pem)

        da = store.find_by_device_code_hash(DeviceAuthorization.hash_device_code(code.to_s))
        if da.nil? || !da.link?
          raise Errors::NotFound.new(
            "unknown link code",
            hint: "the account holder mints one at POST /auth/link (link codes are single-use and short-lived)",
          )
        end
        raise Errors::Conflict.new("link code already used") if da.consumed?

        if da.expired_at_time?(now) && da.approved?
          store.update(da.expire)
          raise Errors::NotFound.new("link code expired")
        end
        raise Errors::NotFound.new("link code expired") if da.expired?

        # The proof comes before the consume, so a failed one leaves the code live.
        payload = PopVerifier.verify!(public_key_pem: pem, signed: signed)
        AuthChallenge.consume!(public_key_pem: pem, nonce: payload.fetch(:nonce))

        # The atomic consume, not `consumed?` above, decides single use under a race.
        claimed = store.claim_consume(da, now: now)
        raise Errors::Conflict.new("link code already used") if claimed.nil?

        result = AccountBinding.bind!(
          public_key_pem: pem,
          user_id:        da.user_id,
          requested_role: da.requested_role,
        )

        { agent_id: result[:agent_id], user_id: result[:user_id], access_token: result[:access_token] }
      end
    end
  end
end
