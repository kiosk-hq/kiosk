# frozen_string_literal: true

require "securerandom"
require "digest"

module Kiosk
  module Server
    # State-machine value object for the account-binding ceremony
    # riding the RFC 8628 Device Authorization Grant wire. One row per
    # binding request, in one of two kinds:
    #
    #   - `:claim` — agent-initiated (auth.md "User Claimed"): created on
    #     POST /oauth/device_authorization carrying the agent's public key,
    #     approved/denied by the human at /oauth/device/verify, consumed by
    #     the polling client at POST /oauth/token (device_code grant).
    #   - `:link` — human-initiated (Kiosk extension): created PRE-APPROVED
    #     and already bound to the signed-in human's user_id at
    #     POST /auth/link; consumed when the agent redeems the link code at
    #     POST /auth/claim.
    #
    # Two codes per row — both persisted as SHA-256 hex digests ONLY (the
    # plain forms are returned exactly once by {.generate} and never
    # reconstructable):
    #
    #   - **device_code**  — long opaque CSPRNG token (~32 bytes base64url).
    #     Returned to the initiating client (claim) or handed to the human
    #     as the link code (link).
    #   - **user_code**    — 8-char code displayed to the human, who
    #     types it at the verification URL (claim only). Drawn from the
    #     31-char read-aloud-unambiguous alphabet defined below (A-Z minus
    #     I/L/O, digits 2-9; U is KEPT) — NOT Crockford base32. See
    #     {USER_CODE_ALPHABET} for why, and for the 31^8 ≈ 8.5 × 10^11 space.
    #
    # `public_key_pem` carries the key the ceremony will bind (nil for
    # `:link` rows until redeem, and for legacy pre-binding rows); `user_id`
    # is stamped at approval (claim) or creation (link).
    #
    # `requested_role` is, on BOTH kinds, the role of the HUMAN this row
    # belongs to — never a role a client asked for (K-072). A `:link` row
    # carries it from creation ({LinkCode.mint} reads `Identity#role` off the
    # minting session); a `:claim` row is born WITHOUT one and receives it at
    # {#approve}, from the identity of whoever approves. `nil` means the
    # provider's `user_idp` reports no role, and the binding then falls back to
    # `registration_role`/absent (ADR-0011's no-regression clause).
    #
    # Lifecycle: `:pending → :approved | :denied → :consumed | :expired`.
    # Transitions are non-destructive — each returns a new instance via
    # `Data#with`. Persistence is up to the configured
    # {DeviceAuthorizationStores::Base} adapter.
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

      # The two ceremony directions: agent-initiated `:claim`
      # (auth.md "User Claimed") and human-initiated `:link` (Kiosk
      # extension).
      KINDS = %i[claim link].freeze

      # 31 read-aloud-unambiguous chars: A-Z minus I/L/O, digits 2-9 (so no
      # 0/1 either). 31^8 ≈ 8.5 × 10^11 possible codes.
      #
      # NOT Crockford base32, and the comment said so until K-888: Crockford
      # KEEPS 0 and 1 and drops U, which is the opposite trade on both counts
      # — it optimises for decoding a string a human typed, while a `user_code`
      # is read off one screen and typed into another, where 0/O and 1/I/L are
      # the pairs that actually get confused. U is kept deliberately; dropping
      # it would buy nothing here and cost 30^8.
      #
      # The count is load-bearing, which is why it is now measured rather than
      # asserted: it is the published justification for the brute-force
      # posture, and the other half of that posture — the verify page's
      # attempt cap (`device_verify_controller.rb`) — lives in the session and
      # so resets on re-authentication. The row's `expires_at` is the hard
      # bound. `spec/kiosk/server/device_authorization_spec.rb` pins the set,
      # the size and the published space against this comment.
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

      # Generate a fresh authorization. Returns
      # [plain_device_code, plain_user_code, da]. The plain codes exist
      # only in this return value; once `da` is persisted (only the hex
      # digests survive), the plain forms are lost.
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

      # SHA-256 hex digest of a plaintext device_code for storage/lookup.
      # Hex (not raw bytes) so the durable store persists it in a plain
      # `text` column — same convention as `agent_tokens.token_hash`.
      def self.hash_device_code(plain_device_code)
        Digest::SHA256.hexdigest(plain_device_code)
      end

      # SHA-256 hex digest of a plaintext user_code for storage/lookup.
      # Callers normalise first (see {DeviceVerification.normalize_user_code});
      # {.generate} produces codes already in the canonical 8-char form.
      def self.hash_user_code(plain_user_code)
        Digest::SHA256.hexdigest(plain_user_code)
      end

      # Human-displayable form of a PLAIN user_code: `XXXX-XXXX`. The dash
      # is purely visual; the verification controller strips dashes /
      # whitespace before matching against the stored digest. A class
      # method because the row itself holds only the hash.
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

      # Whether the row's expires_at has passed. Expiry is enforced by
      # the consuming endpoints (POST /oauth/token and POST /auth/claim
      # read this before binding); the in-DB `status` is bumped to
      # `:expired` lazily on next lookup.
      def expired_at_time?(now = Time.now)
        now >= expires_at
      end

      # Approve a pending row, stamping the approving account holder's
      # `user_id` — and, on a `:claim` row, their ROLE.
      #
      # `role:` is where a claim ceremony's `requested_role` comes from
      # (K-072). A `:claim` row is born role-less because the request that
      # opens it is unauthenticated; the role is captured HERE, at the one
      # moment an authenticated human is present, from `user_idp`'s
      # `Identity#role`. A `:link` row travels the other way — it is minted BY
      # the human, so {LinkCode.mint} already put their role on it via
      # {.generate} and calls this with no `role:` — hence the fallback to the
      # value already on the row rather than an unconditional overwrite: nil
      # means "nothing new to stamp", never "clear it".
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
