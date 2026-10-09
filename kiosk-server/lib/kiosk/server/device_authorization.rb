# frozen_string_literal: true

require "securerandom"
require "digest"

module Kiosk
  module Server
    # One account-binding request on the RFC 8628 device-grant wire: a `:claim`
    # the agent opens and a human approves, or a `:link` a signed-in human
    # creates already approved. Only SHA-256 digests of its two codes are kept.
    #
    # `requested_role` is the role of the human the row belongs to, set by the
    # operator, never by a client.
    #
    # Lifecycle: `:pending → :approved | :denied → :consumed | :expired`.
    class DeviceAuthorization < Data.define(
      :id,
      :device_code_hash,
      :user_code_hash,
      :public_key_pem,
      :kind,
      :client_id,
      :requested_role,
      :status,
      :user_id,
      :expires_at,
      :consumed_at,
      :created_at,
    )
      STATUSES = %i[pending approved denied consumed expired].freeze

      KINDS = %i[claim link].freeze

      # A-Z without I/L/O and digits 2-9: 31^8 ≈ 8.5 × 10^11 codes.
      USER_CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789".chars.freeze
      USER_CODE_LENGTH   = 8

      DEVICE_CODE_BYTES  = 32

      # Seconds.
      DEFAULT_EXPIRES_IN = 900

      # A caller bug, not an OAuth error.
      class StateError < StandardError; end

      # The plain codes exist only in this return value.
      def self.generate(client_id:, kind: :claim, public_key_pem: nil,
                        requested_role: nil, expires_in: DEFAULT_EXPIRES_IN, now: Time.now)
        raise ArgumentError, "client_id required" if client_id.nil? || client_id.to_s.empty?
        raise ArgumentError, "expires_in must be > 0" unless expires_in.positive?

        plain_device_code = SecureRandom.urlsafe_base64(DEVICE_CODE_BYTES)
        plain_user_code = USER_CODE_LENGTH.times.map { USER_CODE_ALPHABET.sample(random: SecureRandom) }.join

        da = new(
          id:               SecureRandom.uuid,
          device_code_hash: hash_device_code(plain_device_code),
          user_code_hash:   hash_user_code(plain_user_code),
          public_key_pem:   public_key_pem,
          kind:             kind,
          client_id:        client_id.to_s,
          requested_role:   requested_role&.to_s,
          status:           :pending,
          user_id:          nil,
          expires_at:       now + expires_in,
          consumed_at:      nil,
          created_at:       now,
        )

        [plain_device_code, plain_user_code, da]
      end

      def self.hash_device_code(plain_device_code)
        Digest::SHA256.hexdigest(plain_device_code)
      end

      # Expects a code already normalised ({DeviceVerification.normalize_user_code}).
      def self.hash_user_code(plain_user_code)
        Digest::SHA256.hexdigest(plain_user_code)
      end

      def self.display_user_code(plain_user_code)
        "#{plain_user_code[0, 4]}-#{plain_user_code[4, 4]}"
      end

      def initialize(status:, kind:, **rest)
        status_sym = status.to_sym
        unless STATUSES.include?(status_sym)
          raise ArgumentError,
            "status must be one of #{STATUSES.inspect}, got #{status.inspect}"
        end
        kind_sym = kind.to_sym
        unless KINDS.include?(kind_sym)
          raise ArgumentError,
            "kind must be one of #{KINDS.inspect}, got #{kind.inspect}"
        end
        super(status: status_sym, kind: kind_sym, **rest)
      end

      def pending?  = status == :pending
      def approved? = status == :approved
      def denied?   = status == :denied
      def consumed? = status == :consumed
      def expired?  = status == :expired

      def claim? = kind == :claim
      def link?  = kind == :link

      # Checked by the consuming endpoints; the stored status lags behind.
      def expired_at_time?(now = Time.now)
        now >= expires_at
      end

      # A nil `role:` keeps the role already on the row (a `:link` row has one).
      def approve(user_id:, role: nil)
        raise StateError, "cannot approve a #{status} authorization" unless pending?
        raise ArgumentError, "user_id required" if user_id.nil?

        with(status: :approved, user_id: user_id, requested_role: role&.to_s || requested_role)
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
    end
  end
end
