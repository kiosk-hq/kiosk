# frozen_string_literal: true

module Kiosk
  module Server
    # The claim ceremony on the RFC 8628 device-grant wire: binds an agent key
    # to an existing human account once the human approves.
    #
    #   .start    — POST /oauth/device_authorization
    #   .exchange — POST /oauth/token (grant_type=device_code)
    module DeviceCodeGrant
      GRANT_TYPE = 'urn:ietf:params:oauth:grant-type:device_code'

      # Seconds; a faster poll gets `slow_down` (RFC 8628 §3.5).
      DEFAULT_POLL_INTERVAL = 5

      # Seconds a poll time is remembered; longer than any code lives.
      POLL_REGISTRY_TTL = 3600
      @poll_registry = {}
      @poll_mutex    = Mutex.new

      PROOF_REQUIRED = 'signed proof-of-possession required ' \
                       '(GET /auth/challenge?public_key=… then sign {aud, nonce, jti})'

      STATUS_FAILURES = {
        pending: [:authorization_pending, 'the account holder has not yet approved'],
        denied: [:access_denied, 'the account holder denied the request'],
        consumed: [:invalid_grant, 'device_code already used'],
        expired: [:expired_token, 'the device_code has expired']
      }.freeze

      module_function

      # No role parameter on purpose: the row takes the approving human's role.
      def start(client_id:,
                public_key_pem:,
                store: Kiosk.configuration.device_authorization_store,
                expires_in: DeviceAuthorization::DEFAULT_EXPIRES_IN,
                now: Time.current)
        plain_device_code, plain_user_code, da = DeviceAuthorization.generate(
          client_id: client_id, kind: :claim, public_key_pem: public_key_pem.to_s.strip,
          expires_in: expires_in, now: now
        )
        store.create(da)
        { device_code: plain_device_code, user_code: DeviceAuthorization.display_user_code(plain_user_code),
          expires_in: expires_in, interval: DEFAULT_POLL_INTERVAL, da: da }
      end

      # Returns `{ok: true, access_token:, …}` or `{ok: false, error:, description:}`
      # with an RFC 8628 §3.5 error code.
      def exchange(device_code:,
                   signed: nil,
                   store: Kiosk.configuration.device_authorization_store,
                   interval: DEFAULT_POLL_INTERVAL,
                   now: Time.current)
        return failure(:invalid_request, 'device_code parameter required') if device_code.to_s.empty?

        hash = DeviceAuthorization.hash_device_code(device_code)
        da   = store.lookup_by_device_code_hash(hash)
        return failure(:invalid_grant, 'unknown device_code') if da.nil?
        return failure(:slow_down, 'polling faster than the advertised interval') if polled_too_fast?(hash, interval, now)

        da = expire_if_due(da, store, now)
        return bind_and_mint(authorization: da, signed: signed, store: store, now: now) if da.approved?

        failure(*STATUS_FAILURES.fetch(da.status))
      end

      def reset_poll_registry!
        @poll_mutex.synchronize { @poll_registry.clear }
      end

      class << self
        private

        def expire_if_due(authorization, store, now)
          return authorization unless authorization.expired_at_time?(now)
          return authorization unless authorization.pending? || authorization.approved?

          store.update(authorization.expire)
        end

        # Possession of the row's key is proven before binding; a failed proof
        # is `invalid_client` and leaves the row approved for a retry.
        def bind_and_mint(authorization:, signed:, store:, now:)
          refusal = possession_refusal(authorization.public_key_pem, signed)
          return refusal if refusal
          # Atomic, so two concurrent polls mint one token.
          return failure(:invalid_grant, 'device_code already used') if store.claim_consume(authorization, now: now).nil?

          token_response(authorization)
        end

        def possession_refusal(public_key_pem, signed)
          return failure(:invalid_client, PROOF_REQUIRED) if signed.nil? || signed.to_s.empty?
          return failure(:invalid_client, 'no public key bound to this authorization') if public_key_pem.blank?

          payload = PopVerifier.verify!(public_key_pem: public_key_pem, signed: signed)
          AuthChallenge.consume!(public_key_pem: public_key_pem, nonce: payload.fetch(:nonce))
          nil
        rescue Errors::Base => e
          failure(:invalid_client, e.message)
        end

        def token_response(authorization)
          role = authorization.requested_role
          result = AccountBinding.bind!(public_key_pem: authorization.public_key_pem,
                                        user_id: authorization.user_id, requested_role: role)
          response = { ok: true, access_token: result[:access_token], token_type: 'Bearer',
                       expires_in: Kiosk.configuration.access_token_ttl }
          # RFC 6749 §5.1: the granted scope is the approving human's role.
          response[:scope] = role if role
          response
        end

        def failure(error, description)
          { ok: false, error: error.to_s, description: description }
        end

        # Per process; a multi-process origin rate-limits at its edge.
        def polled_too_fast?(hash, interval, now)
          @poll_mutex.synchronize do
            @poll_registry.delete_if { |_, at| now - at > POLL_REGISTRY_TTL }
            last = @poll_registry[hash]
            @poll_registry[hash] = now
            !last.nil? && (now - last) < interval
          end
        end
      end
    end
  end
end
