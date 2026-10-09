# frozen_string_literal: true

module Kiosk
  module Server
    # The claim ceremony on the RFC 8628 device-grant wire: binds an agent key
    # to an existing human account once the human approves.
    #
    #   .start    — POST /oauth/device_authorization
    #   .exchange — POST /oauth/token (grant_type=device_code)
    module DeviceCodeGrant
      GRANT_TYPE = "urn:ietf:params:oauth:grant-type:device_code"

      # Seconds; a faster poll gets `slow_down` (RFC 8628 §3.5).
      DEFAULT_POLL_INTERVAL = 5

      # Seconds a poll time is remembered; longer than any code lives.
      POLL_REGISTRY_TTL = 3600
      @poll_registry = {}
      @poll_mutex    = Mutex.new

      module_function

      # No role parameter on purpose: the row takes the approving human's role.
      def start(client_id:,
                public_key_pem:,
                store: Kiosk.configuration.device_authorization_store,
                expires_in: DeviceAuthorization::DEFAULT_EXPIRES_IN,
                now: Time.now)
        plain_device_code, plain_user_code, da = DeviceAuthorization.generate(
          client_id:      client_id,
          kind:           :claim,
          public_key_pem: public_key_pem.to_s.strip,
          expires_in:     expires_in,
          now:            now,
        )
        store.create(da)

        {
          device_code: plain_device_code,
          user_code:   DeviceAuthorization.display_user_code(plain_user_code),
          expires_in:  expires_in,
          interval:    DEFAULT_POLL_INTERVAL,
          da:          da,
        }
      end

      # Returns `{ok: true, access_token:, …}` or `{ok: false, error:, description:}`
      # with an RFC 8628 §3.5 error code.
      def exchange(device_code:,
                   signed: nil,
                   store: Kiosk.configuration.device_authorization_store,
                   interval: DEFAULT_POLL_INTERVAL,
                   now: Time.now)
        if device_code.nil? || device_code.to_s.empty?
          return failure(:invalid_request, "device_code parameter required")
        end

        hash = DeviceAuthorization.hash_device_code(device_code)
        da   = store.find_by_device_code_hash(hash)
        return failure(:invalid_grant, "unknown device_code") if da.nil?

        if polled_too_fast?(hash, interval, now)
          return failure(:slow_down, "polling faster than the advertised interval")
        end

        if da.expired_at_time?(now) && (da.pending? || da.approved?)
          store.update(da.expire)
          return failure(:expired_token, "the device_code has expired")
        end

        case da.status
        when :pending
          failure(:authorization_pending, "the account holder has not yet approved")
        when :denied
          failure(:access_denied, "the account holder denied the request")
        when :consumed
          failure(:invalid_grant, "device_code already used")
        when :expired
          failure(:expired_token, "the device_code has expired")
        when :approved
          bind_and_mint(da: da, signed: signed, store: store, now: now)
        end
      end

      def reset_poll_registry!
        @poll_mutex.synchronize { @poll_registry.clear }
      end

      class << self
        private

        # Possession of the row's key is proven before binding; a failed proof
        # is `invalid_client` and leaves the row approved for a retry.
        def bind_and_mint(da:, signed:, store:, now:)
          if signed.nil? || signed.to_s.empty?
            return failure(
              :invalid_client,
              "signed proof-of-possession required " \
              "(GET /auth/challenge?public_key=… then sign {aud, nonce, jti})",
            )
          end
          if da.public_key_pem.nil? || da.public_key_pem.empty?
            return failure(:invalid_client, "no public key bound to this authorization")
          end

          begin
            payload = PopVerifier.verify!(public_key_pem: da.public_key_pem, signed: signed)
            AuthChallenge.consume!(public_key_pem: da.public_key_pem, nonce: payload.fetch(:nonce))
          rescue Errors::Base => e
            return failure(:invalid_client, e.message)
          end

          # Atomic, so two concurrent polls mint one token.
          if store.claim_consume(da, now: now).nil?
            return failure(:invalid_grant, "device_code already used")
          end

          result = AccountBinding.bind!(
            public_key_pem: da.public_key_pem,
            user_id:        da.user_id,
            requested_role: da.requested_role,
          )

          response = {
            ok:           true,
            access_token: result[:access_token],
            token_type:   "Bearer",
            expires_in:   JwtIssuer::DEFAULT_EXPIRES_IN,
          }
          # RFC 6749 §5.1: the granted scope is the approving human's role.
          response[:scope] = da.requested_role if da.requested_role
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
