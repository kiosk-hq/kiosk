# frozen_string_literal: true

module Kiosk
  module Redteam
    # What an origin tells the generic scenarios about itself. A nil field skips
    # the scenarios that need that surface.
    #
    #   pow_difficulty        >0 when /register is gated by a PoW toll; 0 skips RegistrationWithoutPow
    #   declared_roles        the roles the origin declares; DeviceGrantRoleSelfSelection needs a real one
    #   requires_kyc          whether the gated action needs a KYC attestation
    #   currency              the ISO 4217 code the origin prices in, lower case (WrongCurrencyCart)
    #   per_user_query        query returning the caller's own rows (CrossTenantRead)
    #   row_id_key            key of a row's id in query results
    #   result_id_key         key of the new resource's id in forge_action's result
    #   create_owned          (client, principal) -> Hash with at least :id
    #   forge_action          action whose caller-supplied user_id the server must ignore
    #   forge_args            (client, principal_a, principal_b) -> Hash, without user_id
    #   gated_action          action gated behind payment (and KYC when requires_kyc)
    #   gated_action_consumes false when calling gated_action twice is correct (skips SpentResourceReuse)
    #   gated_args            (owned_ref) -> Hash
    #   pay_for               (client, principal, owned_ref) -> { intent:, cart: }
    #   kyc_valid             (user_id) -> a valid attestation JWS
    #   kyc_expired           (user_id) -> an expired attestation JWS
    #   kyc_forged            (user_id) -> an attestation with a wrong issuer or signature
    class Profile
      DEFAULTS = {
        pow_difficulty: 0,
        declared_roles: [],
        currency: nil,
        requires_kyc: false,
        per_user_query: nil,
        row_id_key: 'id',
        result_id_key: nil,
        create_owned: nil,
        forge_action: nil,
        forge_args: nil,
        gated_action: nil,
        gated_action_consumes: true,
        gated_args: nil,
        pay_for: nil,
        kyc_valid: nil,
        kyc_expired: nil,
        kyc_forged: nil
      }.freeze

      attr_reader(*DEFAULTS.keys)

      def initialize(**fields)
        unknown = fields.keys - DEFAULTS.keys
        raise ArgumentError, "unknown keywords: #{unknown.join(', ')}" unless unknown.empty?

        DEFAULTS.merge(fields).each { |field, value| instance_variable_set(:"@#{field}", value) }
        @declared_roles = Array(declared_roles).map(&:to_s).reject(&:empty?).uniq
        @result_id_key ||= row_id_key
      end
    end
  end
end
