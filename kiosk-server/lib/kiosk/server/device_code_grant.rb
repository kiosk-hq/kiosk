# frozen_string_literal: true

module Kiosk
  module Server
    # Pure-Ruby service module for the RFC 8628 Device Authorization
    # Grant flow. Two entry points:
    #
    #   .start    — POST /oauth/device_authorization handler logic
    #   .exchange — POST /oauth/token (grant_type=device_code) handler
    #                logic
    #
    # Controllers in this gem are thin shims over these methods — the
    # same way {ExecController} is a shim over {Executor}. Logic lives
    # here so unit tests don't require a Rails environment, and so the
    # service is reachable from non-Rails hosts (Rack apps, batch jobs,
    # tests that simulate the OAuth interactions in-process).
    #
    # See design spec §6.5 (Device Grant) + §6.7 (OAuth surface).
    module DeviceCodeGrant
      # OAuth grant_type literal per RFC 8628 §3.4.
      GRANT_TYPE = "urn:ietf:params:oauth:grant-type:device_code"

      # Recommended polling interval (seconds) the server tells the
      # client to honour. Clients that ignore receive `slow_down` and
      # MUST bump their interval by 5s (RFC 8628 §3.5). 5s is a sane
      # default; ergonomic for human-interactive flows.
      DEFAULT_POLL_INTERVAL = 5

      module_function

      # Issue a new device authorization. The first item of the pair is
      # the plain `device_code` to return to the client; the second is
      # the persisted row (already in the store). Caller composes the
      # full /oauth/device_authorization HTTP response from the result.
      #
      # @return [Hash] {device_code:, user_code:, expires_in:, interval:, da:}
      def start(client_id:,
                requested_role: nil,
                store: Kiosk.configuration.device_authorization_store,
                expires_in: DeviceAuthorization::DEFAULT_EXPIRES_IN,
                now: Time.now)
        plain_device_code, da = DeviceAuthorization.generate(
          client_id:      client_id,
          requested_role: requested_role,
          expires_in:     expires_in,
          now:            now,
        )
        store.create(da)

        {
          device_code: plain_device_code,
          user_code:   da.display_user_code,
          expires_in:  expires_in,
          interval:    DEFAULT_POLL_INTERVAL,
          da:          da,
        }
      end

      # Exchange a polled device_code for an access token. State-machine
      # outcomes map to RFC 8628 §3.5 error codes; the success case
      # transitions the row to `:consumed` (preventing reuse) and
      # returns a JWT.
      #
      # @return [Hash] success: {ok: true, access_token:, token_type:, expires_in:, scope:}
      #                failure: {ok: false, error: <RFC code>, description:}
      def exchange(device_code:,
                   store: Kiosk.configuration.device_authorization_store,
                   signing_key: Kiosk.configuration.signing_key,
                   issuer: Kiosk.configuration.issuer,
                   audience: nil,
                   token_expires_in: JwtIssuer::DEFAULT_EXPIRES_IN,
                   now: Time.now)
        if device_code.nil? || device_code.to_s.empty?
          return failure(:invalid_request, "device_code parameter required")
        end

        hash = DeviceAuthorization.hash_device_code(device_code)
        da   = store.find_by_device_code_hash(hash)
        return failure(:invalid_grant, "unknown device_code") if da.nil?

        # Lazy expiry — bump status BEFORE state check so subsequent
        # polls see `:expired` rather than re-checking the clock.
        if da.expired_at_time?(now) && (da.pending? || da.approved?)
          store.update(da.expire)
          return failure(:expired_token, "the device_code has expired")
        end

        case da.status
        when :pending
          failure(:authorization_pending, "user has not yet approved")
        when :denied
          failure(:access_denied, "user denied authorization")
        when :consumed
          failure(:invalid_grant, "device_code already used")
        when :expired
          failure(:expired_token, "the device_code has expired")
        when :approved
          mint_token(
            da:               da,
            store:            store,
            signing_key:      signing_key,
            issuer:           issuer,
            audience:         audience || issuer,
            token_expires_in: token_expires_in,
            now:              now,
          )
        end
      end

      # ─── helpers ──────────────────────────────────────────────────────

      class << self
        private

        def mint_token(da:, store:, signing_key:, issuer:, audience:, token_expires_in:, now:)
          claims = {
            sub:       da.user_id,
            client_id: da.client_id,
          }
          claims[:role] = da.requested_role if da.requested_role

          token = JwtIssuer.issue(
            claims:      claims,
            audience:    audience,
            signing_key: signing_key,
            issuer:      issuer,
            expires_in:  token_expires_in,
            now:         now,
          )

          store.update(da.consume(now: now))

          response = {
            ok:           true,
            access_token: token,
            token_type:   "Bearer",
            expires_in:   token_expires_in,
          }
          response[:scope] = da.requested_role if da.requested_role
          response
        end

        def failure(error, description)
          { ok: false, error: error.to_s, description: description }
        end
      end
    end
  end
end
