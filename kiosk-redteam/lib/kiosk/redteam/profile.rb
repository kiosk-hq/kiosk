# frozen_string_literal: true

module Kiosk
  module Redteam
    # Provider-specific configuration supplied to each generic attack scenario.
    #
    # A Profile tells scenarios everything they need to know about the provider
    # under test — which actions exist, how to create owned resources, how to
    # build payment mandates, and how to mint KYC attestations for test variants.
    # No provider name is hard-coded in the gem; all provider knowledge lives
    # here, supplied by the demo that boots the redteam battery.
    #
    # == Required fields (nil = skip scenarios that need that surface)
    #
    # @!attribute pow_difficulty [Integer]
    #   Minimum leading zero bits required by the PoW gate on /register.
    #   0 means no PoW is required; {RegistrationWithoutPow} is skipped.
    #
    # @!attribute requires_kyc [Boolean]
    #   Whether the provider's gated action requires a prior KYC attestation.
    #   When false, all KYC scenarios ({MissingKyc}, {ExpiredKyc}, {ForgedKyc})
    #   are skipped.
    #
    # @!attribute per_user_query [String, nil]
    #   Name of the named query that returns the authenticated principal's own
    #   rows (e.g. "my_orders", "my_reservations").  Required by
    #   {CrossTenantRead}; skipped when nil.
    #
    # @!attribute row_id_key [String]
    #   The key in each returned row hash that holds the resource ID.
    #   Defaults to "id".
    #
    # @!attribute create_owned [#call, nil]
    #   Callable: `(client, principal) -> owned_ref (Hash)`.
    #   Creates a resource owned by `principal` and returns a Hash with at
    #   least `:id` (String) and any extra keys needed downstream.
    #   Required by {CrossTenantRead}, {ForgedUserId} (indirectly),
    #   {UnpaidGatedAction}, {MissingKyc}, {SpentResourceReuse},
    #   {PayForOtherUseSelf}.  Skipped when nil.
    #
    # @!attribute forge_action [String, nil]
    #   Name of the run action that accepts a `user_id` argument which the
    #   server should ignore (ownership must derive from the authenticated
    #   token, not caller-supplied).  Required by {ForgedUserId}; skipped
    #   when nil.
    #
    # @!attribute forge_args [#call, nil]
    #   Callable: `(client, principal_a, principal_b) -> Hash`.
    #   Returns the base arguments for `forge_action` (without `user_id`),
    #   using the provided client and principals if needed (e.g. to look up
    #   a resource code).  The scenario injects `user_id: a.user_id`.
    #
    # @!attribute gated_action [String, nil]
    #   Name of the run action that is gated behind payment (and optionally
    #   KYC).  Required by {UnpaidGatedAction}, {MissingKyc}, {ExpiredKyc},
    #   {ForgedKyc}, {SpentResourceReuse}, {PayForOtherUseSelf}; skipped
    #   when nil.
    #
    # @!attribute gated_args [#call, nil]
    #   Callable: `(owned_ref) -> Hash`.
    #   Returns the arguments for `gated_action` given an owned_ref.
    #
    # @!attribute pay_for [#call, nil]
    #   Callable: `(client, principal, owned_ref) -> { intent: Hash, cart: Hash }`.
    #   Builds the intent and cart mandate payloads for the given principal and
    #   resource.  The scenario submits these via `client.pay`.  Required by
    #   {MandatePrincipalSwap}, {MandateReplay}, {SpentResourceReuse},
    #   {PayForOtherUseSelf}; skipped when nil.
    #
    # @!attribute kyc_valid [#call, nil]
    #   Callable: `(user_id) -> JWS String`.
    #   Mints a valid, unexpired KYC attestation for the given user_id.
    #   nil when the provider does not use KYC.
    #
    # @!attribute kyc_expired [#call, nil]
    #   Callable: `(user_id) -> JWS String`.
    #   Mints an expired KYC attestation (exp in the past).
    #   nil when the provider does not use KYC.
    #
    # @!attribute kyc_forged [#call, nil]
    #   Callable: `(user_id) -> JWS String`.
    #   Mints a KYC attestation with a wrong issuer or bad signature.
    #   nil when the provider does not use KYC.
    class Profile
      attr_reader :pow_difficulty,
                  :requires_kyc,
                  :per_user_query,
                  :row_id_key,
                  :create_owned,
                  :forge_action,
                  :forge_args,
                  :gated_action,
                  :gated_args,
                  :pay_for,
                  :kyc_valid,
                  :kyc_expired,
                  :kyc_forged

      def initialize(
        pow_difficulty: 0,
        requires_kyc: false,
        per_user_query: nil,
        row_id_key: "id",
        create_owned: nil,
        forge_action: nil,
        forge_args: nil,
        gated_action: nil,
        gated_args: nil,
        pay_for: nil,
        kyc_valid: nil,
        kyc_expired: nil,
        kyc_forged: nil
      )
        @pow_difficulty = pow_difficulty
        @requires_kyc   = requires_kyc
        @per_user_query = per_user_query
        @row_id_key     = row_id_key
        @create_owned   = create_owned
        @forge_action   = forge_action
        @forge_args     = forge_args
        @gated_action   = gated_action
        @gated_args     = gated_args
        @pay_for        = pay_for
        @kyc_valid      = kyc_valid
        @kyc_expired    = kyc_expired
        @kyc_forged     = kyc_forged
      end
    end
  end
end
