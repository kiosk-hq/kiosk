# frozen_string_literal: true

require "jwt"

module Kiosk
  module Server
    # Verifies a KYC attestation JWS submitted by an agent.
    #
    # Expected JWS payload:
    #   { sub: <user_id>, level: "verified", iss: <kyc_issuer>, aud: <kyc_audience>,
    #     iat: <unix>, exp: <unix>, attributes: { <name>: true, ... } }
    #   # attributes OPTIONAL
    #
    # Verified against `Kiosk.configuration.kyc_public_key` (RS256).
    # Checks: `level == "verified"` (case-sensitive — an unverified/other-level
    # attestation is rejected), correct issuer, `aud` matches this operator's
    # configured `kyc_audience` (OPERATOR-BINDING — a claim the KYC provider
    # minted for another operator is rejected at the WIRE, not merely by a
    # demo's own callback), `sub` matches the authenticated identity (compared
    # as String on both sides so a bigint-PK host works), and not expired.
    # Raises `Errors::Forbidden` on any failure.
    #
    # NAMED ANONYMIZED ATTRIBUTES: the attestation MAY carry an `attributes`
    # object of `{name: true}` booleans (e.g. `{"age_over_18": true,
    # "licence_a": true}`). These are the ONLY facts the provider learns and
    # records — the underlying documents (DOB, licence number) never reach the
    # provider and are never stored or logged here. The field is additive: a
    # bare `level: "verified"` attestation with no `attributes` still verifies
    # (backward-compatible binary path), yielding an empty attribute set.
    # Only booleans that are literally `true` are honoured; any non-`true`
    # value (false / string / number) is dropped, so a caller cannot smuggle
    # a truthy-but-not-true grant past a downstream `== true` gate.
    module KycVerifier
      module_function

      # @param raw_jws  [String]          compact JWS string
      # @param identity [Kiosk::Identity] the authenticated principal
      # @return [Hash] symbol-keyed payload claims on success
      # @raise [Errors::Forbidden] on any verification failure
      def verify(raw_jws:, identity:)
        config = Kiosk.configuration
        key    = config.kyc_public_key

        raise Errors::Forbidden.new(
          "kyc_public_key not configured",
          hint: "Set Kiosk.configuration.kyc_public_key to the KYC provider's RSA public key",
        ) if key.nil?

        payload, = ::JWT.decode(
          raw_jws, key, true,
          algorithms:       ["RS256"],
          verify_expiration: true,
          required_claims:  ["exp", "iss", "aud", "sub"],
        )
        payload  = payload.transform_keys(&:to_sym)

        if payload[:iss] != config.kyc_issuer
          raise Errors::Forbidden.new(
            "KYC attestation issuer mismatch",
            hint: "expected #{config.kyc_issuer.inspect}, got #{payload[:iss].inspect}",
          )
        end

        # OPERATOR-BINDING (aud): the attestation MUST be minted for THIS
        # operator. `aud` is compared as String on both sides (an operator may
        # declare its audience as a plain handle or its origin URL). A claim the
        # KYC provider minted for a DIFFERENT operator's audience is rejected
        # HERE — at the wire, on every operator's `POST /kiosk/agents/kyc` —
        # so a cross-operator claim replay cannot unlock this operator even if a
        # demo skipped its own callback-layer check.
        if payload[:aud].to_s != config.kyc_audience.to_s
          raise Errors::Forbidden.new(
            "KYC attestation audience mismatch",
            hint: "aud must equal this operator's kyc_audience " \
                  "(expected #{config.kyc_audience.inspect}, got #{payload[:aud].inspect})",
          )
        end

        # Compare the principal as STRING on BOTH sides (mirroring
        # MandateVerifier). On a bigint-PK host the authenticated Identity
        # carries the raw Integer that the token `sub` round-trips as, while the
        # KYC provider signs `sub` with whatever id it was handed (a String). A
        # strict `==` ("42" == 42) is always false, so every KYC attestation on
        # a bigint host was wrongly Forbidden. Normalising keeps uuid hosts as-is.
        unless payload[:sub].to_s == identity.user_id.to_s
          raise Errors::Forbidden.new(
            "KYC attestation subject mismatch",
            hint: "sub must equal the authenticated user_id",
          )
        end

        # I1: require the KYC level to be exactly "verified" (case-sensitive).
        unless payload[:level] == "verified"
          raise Errors::Forbidden.new("kyc level not verified")
        end

        # Normalise the (optional) named attributes into a String-keyed hash of
        # only-`true` booleans. Anonymized: these booleans are the only facts
        # kept — no DOB, licence number, or document ever appears here.
        payload[:attributes] = verified_attributes(payload[:attributes])

        payload
      rescue ::JWT::ExpiredSignature
        raise Errors::Forbidden.new("KYC attestation expired")
      rescue ::JWT::MissingRequiredClaim => e
        raise Errors::Forbidden.new("KYC attestation missing required claim: #{e.message}")
      rescue ::JWT::DecodeError => e
        raise Errors::Forbidden.new("KYC attestation signature invalid: #{e.message}")
      end

      # Reduce a raw `attributes` claim to a String-keyed hash of the names the
      # attestation grants as boolean `true`. A missing/nil claim yields `{}`
      # (the binary-only backward-compat path). A non-object claim is rejected
      # as a malformed attestation. Only literal `true` counts — a `false` /
      # string / number value is silently dropped (not granted).
      def verified_attributes(raw)
        return {} if raw.nil?

        unless raw.is_a?(Hash)
          raise Errors::Forbidden.new(
            "KYC attestation attributes must be an object of {name: true} booleans",
          )
        end

        raw.each_with_object({}) do |(name, value), acc|
          acc[name.to_s] = true if value == true
        end
      end
    end
  end
end
