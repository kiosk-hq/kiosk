# frozen_string_literal: true

require "securerandom"
require "digest"

module Kiosk
  module Server
    # State-machine value object for the RFC 8628 Device Authorization
    # Grant flow. One row per device-authorization request: created on
    # POST /oauth/device_authorization, mutated by user approval at
    # /oauth/device/verify, consumed by the polling client at POST
    # /oauth/token (device_code grant). (No first-party CLI ships in 0.1;
    # the initiating client is any RFC 8628 device-grant client.)
    #
    # Two codes per row:
    #
    #   - **device_code**  — long opaque CSPRNG token (~32 bytes
    #     base64url). Returned to the initiating client in the
    #     /oauth/device_authorization response. Persisted only as
    #     SHA-256 digest (`device_code_hash`); plain form is throw-away.
    #   - **user_code**    — 8-char Crockford-alphabet code displayed
    #     to the human, who types it at the verification URL.
    #     Crockford-style (no 0/O/1/I/L/U) avoids confusion at typing.
    #
    # Lifecycle: `:pending → :approved | :denied → :consumed | :expired`.
    # Transitions are non-destructive — each returns a new instance via
    # `Data#with`. Persistence is up to the configured
    # {DeviceAuthorizationStores::Base} adapter.
    class DeviceAuthorization < Data.define(
      :id,
      :device_code_hash,
      :user_code,
      :client_id,
      :requested_role,
      :status,
      :user_id,
      :expires_at,
      :consumed_at,
      :created_at,
    )
      STATUSES = %i[pending approved denied consumed expired].freeze

      # Crockford-style alphabet — 32 unambiguous chars (no 0/O/1/I/L/U).
      # 32^8 ≈ 1.1 × 10^12 possible codes; brute-force is gated by
      # /oauth/token's poll-interval + the row's `expires_at`.
      USER_CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789".chars.freeze
      USER_CODE_LENGTH   = 8

      # 32 bytes ≈ 256 bits of entropy. Returned exactly once to the
      # initiating client; never reconstructable from `device_code_hash`.
      DEVICE_CODE_BYTES  = 32

      # Default OAuth device-flow lifetime (RFC 8628 §3.2 example: 1800;
      # we pick 900 to bias toward fresh codes since interactive
      # device-grant approval sessions complete in <2 min usually).
      DEFAULT_EXPIRES_IN = 900

      # Raised on attempted illegal state transition (e.g. approving an
      # already-consumed row). Indicates a logic error in the calling
      # controller, not a user-visible OAuth error.
      class StateError < StandardError; end

      # Generate a fresh authorization. Returns [plain_device_code, da].
      # The plain code is the only opportunity to reveal it; once `da`
      # is persisted (only the hash survives), the plain form is lost.
      def self.generate(client_id:, requested_role: nil, expires_in: DEFAULT_EXPIRES_IN, now: Time.now)
        raise ArgumentError, "client_id required" if client_id.nil? || client_id.to_s.empty?
        raise ArgumentError, "expires_in must be > 0" unless expires_in.positive?

        plain_device_code = SecureRandom.urlsafe_base64(DEVICE_CODE_BYTES)
        user_code = USER_CODE_LENGTH.times.map { USER_CODE_ALPHABET.sample(random: SecureRandom) }.join

        da = new(
          id:               SecureRandom.uuid,
          device_code_hash: Digest::SHA256.digest(plain_device_code),
          user_code:        user_code,
          client_id:        client_id.to_s,
          requested_role:   requested_role&.to_s,
          status:           :pending,
          user_id:          nil,
          expires_at:       now + expires_in,
          consumed_at:      nil,
          created_at:       now,
        )

        [plain_device_code, da]
      end

      # Compute the SHA-256 hash of a plaintext device_code for lookup.
      def self.hash_device_code(plain_device_code)
        Digest::SHA256.digest(plain_device_code)
      end

      def initialize(status:, **rest)
        status_sym = status.to_sym
        unless STATUSES.include?(status_sym)
          raise ArgumentError,
            "status must be one of #{STATUSES.inspect}, got #{status.inspect}"
        end
        super(status: status_sym, **rest)
      end

      def pending?  = status == :pending
      def approved? = status == :approved
      def denied?   = status == :denied
      def consumed? = status == :consumed
      def expired?  = status == :expired

      # Whether the row's expires_at has passed. Expiry is enforced by
      # the polling controller (POST /oauth/token reads this before
      # serving a token); the in-DB `status` is bumped to `:expired` by
      # a periodic sweep job or lazily on next lookup.
      def expired_at_time?(now = Time.now)
        now >= expires_at
      end

      def approve(user_id:)
        raise StateError, "cannot approve a #{status} authorization" unless pending?
        raise ArgumentError, "user_id required" if user_id.nil?

        with(status: :approved, user_id: user_id)
      end

      def deny
        raise StateError, "cannot deny a #{status} authorization" unless pending?
        with(status: :denied)
      end

      def consume(now: Time.now)
        raise StateError, "cannot consume a #{status} authorization" unless approved?
        with(status: :consumed, consumed_at: now)
      end

      def expire
        unless pending? || approved?
          raise StateError, "cannot expire a #{status} authorization"
        end
        with(status: :expired)
      end

      # Human-displayable form: `XXXX-XXXX`. The dash is purely visual;
      # the verification controller strips dashes / whitespace before
      # matching against the stored code.
      def display_user_code
        "#{user_code[0, 4]}-#{user_code[4, 4]}"
      end
    end
  end
end
