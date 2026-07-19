# frozen_string_literal: true

module Kiosk
  module Server
    # Pure-Ruby service module for the claim half of the account-binding
    # ceremony on the RFC 8628 Device Authorization Grant wire.
    # Two entry points:
    #
    #   .start    — POST /oauth/device_authorization handler logic
    #   .exchange — POST /oauth/token (grant_type=device_code) handler
    #                logic
    #
    # == Why Kiosk keeps this alongside proof-of-possession auth
    #
    # The primary auth is proof-of-possession (/auth/challenge → /auth/register
    # | /auth/login): an agent proves it holds a private key and gets a token
    # bound to a synthetic principal — no human. The claim ceremony serves the
    # ONE case PoP cannot: binding an agent key to an *existing HUMAN*
    # account (auth.md "User Claimed"). The request carries the agent's
    # public key; the human approves the `user_code` on the provider's
    # session-authenticated verify page, and {DeviceVerification.approve}
    # attaches the authorization to THAT `user_id`. The poll then proves
    # possession of the key (BIND-POP) and {AccountBinding.bind!} creates the
    # durable key→account link — fresh key registers a linked assistant
    # account, known key rebinds with its reputation carried over. The token
    # returned is a standard kiosk-pop JWT (same {AgentIdentityProviders::
    # DefaultAgentIdp} path as /auth/login); thereafter the agent refreshes
    # via /auth/login — the ceremony never repeats.
    #
    # It is NOT gated by KYC — human approval + key possession are the only
    # preconditions (KYC stays agent-only).
    #
    # Controllers in this gem are thin shims over these methods — the
    # same way {WireController} is a shim over {Executor}. Logic lives
    # here so unit tests don't require a Rails environment, and so the
    # service is reachable from non-Rails hosts (Rack apps, batch jobs,
    # tests that simulate the OAuth interactions in-process).
    module DeviceCodeGrant
      # OAuth grant_type literal per RFC 8628 §3.4.
      GRANT_TYPE = "urn:ietf:params:oauth:grant-type:device_code"

      # Recommended polling interval (seconds) the server tells the
      # client to honour. Clients that ignore it receive `slow_down` and
      # MUST bump their interval by 5s (RFC 8628 §3.5). 5s is a sane
      # default; ergonomic for human-interactive flows.
      DEFAULT_POLL_INTERVAL = 5

      # In-process poll-rate registry entries older than this are pruned
      # (a code's usable life is DEFAULT_EXPIRES_IN = 900s; one hour is a
      # comfortable superset).
      POLL_REGISTRY_TTL = 3600
      @poll_registry = {}
      @poll_mutex    = Mutex.new

      module_function

      # Issue a new claim authorization. `public_key_pem` is REQUIRED — the
      # ceremony's product is a binding for exactly this key, and the
      # possession proof at the poll verifies against it (BIND-POP). The
      # caller (controller) has already run {PopVerifier.load_public_key}
      # so only well-formed RSA-2048+ keys reach here.
      #
      # @return [Hash] {device_code:, user_code:, expires_in:, interval:, da:}
      #   `user_code` is the display form (XXXX-XXXX); only its hash is
      #   persisted.
      def start(client_id:,
                public_key_pem:,
                requested_role: nil,
                store: Kiosk.configuration.device_authorization_store,
                expires_in: DeviceAuthorization::DEFAULT_EXPIRES_IN,
                now: Time.now)
        plain_device_code, plain_user_code, da = DeviceAuthorization.generate(
          client_id:      client_id,
          kind:           :claim,
          public_key_pem: public_key_pem.to_s.strip,
          requested_role: requested_role,
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

      # Exchange a polled device_code for an access token. State-machine
      # outcomes map to RFC 8628 §3.5 error codes. On an approved row the
      # poll MUST carry `signed` — the same challenge-response JWS over
      # {aud, nonce, jti} as register/login — verified against the row's
      # public key BEFORE any binding (BIND-POP: failed proof →
      # `invalid_client`, the row is NOT consumed, the client may retry
      # with a valid proof). A valid proof binds via {AccountBinding.bind!},
      # consumes the row (single-use) and returns a standard kiosk-pop JWT.
      #
      # @return [Hash] success: {ok: true, access_token:, token_type:, expires_in:, scope:}
      #                failure: {ok: false, error: <RFC code>, description:}
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

        # RFC 8628 §3.5 slow_down: a client polling faster than the
        # advertised interval is told to back off (and MUST add 5s).
        if polled_too_fast?(hash, interval, now)
          return failure(:slow_down, "polling faster than the advertised interval")
        end

        # Lazy expiry — bump status BEFORE state check so subsequent
        # polls see `:expired` rather than re-checking the clock.
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

      # Test/dev helper: forget all recorded poll times (the slow_down
      # registry is process-local state, like {DeviceAuthorizationStores::
      # InMemory#reset!}).
      def reset_poll_registry!
        @poll_mutex.synchronize { @poll_registry.clear }
      end

      # ─── helpers ──────────────────────────────────────────────────────

      class << self
        private

        # BIND-POP: possession of the row's key is
        # proven BEFORE the binding is created. Any proof failure —
        # missing `signed`, bad signature, stale/missing challenge nonce —
        # maps to OAuth `invalid_client` and leaves the row approved.
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

          result = AccountBinding.bind!(
            public_key_pem: da.public_key_pem,
            user_id:        da.user_id,
            requested_role: da.requested_role,
          )
          store.update(da.consume(now: now))

          response = {
            ok:           true,
            access_token: result[:access_token],
            token_type:   "Bearer",
            expires_in:   JwtIssuer::DEFAULT_EXPIRES_IN,
          }
          response[:scope] = da.requested_role if da.requested_role
          response
        end

        def failure(error, description)
          { ok: false, error: error.to_s, description: description }
        end

        # Record this poll and report whether the PREVIOUS one was less
        # than `interval` seconds ago. In-process state (like the default
        # challenge/spent stores); a multi-process deployment that wants
        # cross-process poll accounting fronts the endpoint with its own
        # rate limiter.
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
