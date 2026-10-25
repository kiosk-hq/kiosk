# frozen_string_literal: true

module Kiosk
  module Server
    # The claim ceremony on the RFC 8628 device-grant endpoints: binds a registered
    # client to an existing human account once the human approves.
    #
    #   .start     — POST /oauth/device_authorization
    #   .pay_toll! — POST /oauth/token (grant_type=device_code), before the client authenticates
    #   .exchange  — POST /oauth/token (grant_type=device_code), after it authenticates
    module DeviceCodeGrant
      GRANT_TYPE = Client::DEVICE_CODE

      # Seconds; a faster poll gets `slow_down` (RFC 8628 §3.5).
      DEFAULT_POLL_INTERVAL = 5

      # Seconds a poll time is remembered; longer than any code lives.
      POLL_REGISTRY_TTL = 3600
      @poll_registry = {}
      @poll_mutex    = Mutex.new

      STATUS_FAILURES = {
        pending: [:authorization_pending, 'the account holder has not yet approved'],
        denied: [:access_denied, 'the account holder denied the request'],
        consumed: [:invalid_grant, 'device_code already used'],
        expired: [:expired_token, 'the device_code has expired']
      }.freeze

      module_function

      # No role parameter on purpose: the client takes the approving human's role.
      def start(client:,
                store: Kiosk.configuration.device_authorization_store,
                expires_in: DeviceAuthorization::DEFAULT_EXPIRES_IN,
                now: Time.current)
        plain_device_code, plain_user_code, da = DeviceAuthorization.generate(
          client_id: client.id, kind: :claim, public_key_pem: client.public_key_pem,
          expires_in: expires_in, now: now
        )
        store.create(da)
        { device_code: plain_device_code, user_code: DeviceAuthorization.display_user_code(plain_user_code),
          expires_in: expires_in, interval: DEFAULT_POLL_INTERVAL, da: da }
      end

      # The first poll of each device code value is tolled; later polls
      # of that value are free until any code could have expired. The store is
      # not read first, so an unknown code costs the same work as a live one.
      def pay_toll!(device_code, pow, now: Time.current)
        config = Kiosk.configuration
        paid   = "device_code:#{DeviceAuthorization.hash_device_code(device_code)}"
        return if !AuthToll.on?(config) || config.pow_spent_store.spent?(paid)

        AuthToll.gate(verb: 'oauth/token', body: { device_code: device_code.to_s }, pow: pow, config: config)
        config.pow_spent_store.mark_spent(paid, now.to_i + DeviceAuthorization::DEFAULT_EXPIRES_IN)
      end

      # @return [Client] the client under the approving human's account
      # @raise [OauthError] with an RFC 8628 §3.5 error code
      def exchange(device_code:, client:,
                   store: Kiosk.configuration.device_authorization_store,
                   interval: DEFAULT_POLL_INTERVAL,
                   now: Time.current)
        hash = DeviceAuthorization.hash_device_code(device_code)
        da = authorization_of(client, store.lookup_by_device_code_hash(hash))
        fail!(:slow_down, 'polling faster than the advertised interval') if polled_too_fast?(hash, interval, now)

        consume!(expire_if_due(da, store, now), store, now)
        AccountBinding.bind!(agent_id: client.id, user_id: da.user_id, requested_role: da.requested_role)
      end

      def reset_poll_registry!
        @poll_mutex.synchronize { @poll_registry.clear }
      end

      class << self
        private

        # A claim row that this client opened; a row of another client is unknown to it.
        def authorization_of(client, authorization)
          return authorization if authorization&.claim? && authorization.client_id == client.id

          fail!(:invalid_grant, 'unknown device_code')
        end

        def expire_if_due(authorization, store, now)
          return authorization unless authorization.expired_at_time?(now)
          return authorization unless authorization.pending? || authorization.approved?

          store.update(authorization.expire)
        end

        # Atomic, so two concurrent polls bind once.
        def consume!(authorization, store, now)
          fail!(*STATUS_FAILURES.fetch(authorization.status)) unless authorization.approved?
          fail!(:invalid_grant, 'device_code already used') if store.claim_consume(authorization, now: now).nil?
        end

        def fail!(error, description)
          raise OauthError.new(error, description)
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
