# frozen_string_literal: true

require "json"
require "base64"

module Kiosk
  module Redteam
    # Base class for all adversarial scenarios.
    #
    # Subclasses override {#call} to drive a hostile request sequence against
    # the provider and return a {Verdict}.
    #
    # A scenario PASSES (blocked: true) when the provider correctly rejects
    # the attack.  A scenario that finds a real breach must return
    # blocked: false — the Runner then exits non-zero.
    #
    # When a profile lacks the surface a scenario needs, {#call} returns a
    # skip Verdict (blocked: true, detail: "SKIP — …") so the battery still
    # exits zero without exercising the missing gate.
    #
    # @abstract Override {#call} in subclasses.
    class Scenario
      # @return [String] short human-readable name used in Runner output
      attr_reader :name

      # @return [String] attack category (e.g. "authorization", "mandate", "kyc")
      attr_reader :category

      # @return [String] description of what this scenario tests
      attr_reader :description

      def initialize(name:, category:, description:)
        @name        = name
        @category    = category
        @description = description
      end

      # Execute the adversarial scenario.
      #
      # @param client  [Client]  HTTP driver pointed at the provider under test
      # @param profile [Profile] provider-specific configuration
      # @return [Verdict]
      def call(client, profile) # rubocop:disable Lint/UnusedMethodArgument
        raise NotImplementedError, "#{self.class}#call is not implemented"
      end

      private

      # Return a skip Verdict when the profile lacks the surface this scenario
      # exercises.  A skip is NOT a pass — it is a distinct third state that
      # does not count towards the blocked count and does not fail the battery.
      # The expected-applicable assertion in each demo catches spurious skips.
      #
      # @param reason [String] human-readable reason, e.g. "no per_user_query"
      # @return [Verdict]
      def skip_verdict(reason)
        Verdict.new(blocked: false, skipped: true, status: 0, detail: "SKIP — #{reason}")
      end

      # Wrap a server Response into a Verdict using the canonical blocked? helper.
      #
      # @param response [Response]
      # @param detail   [String] extra context to append on breach
      # @return [Verdict]
      def verdict_from(response, detail: nil)
        blocked = Kiosk::Redteam.blocked?(response)
        Verdict.new(
          blocked: blocked,
          skipped: false,
          status:  response.status,
          detail:  blocked ? "" : (detail || "HTTP #{response.status}: #{response.body.inspect}"),
        )
      end

      # Register a principal, solving PoW at the profile difficulty.
      #
      # @param client  [Client]
      # @param name    [String]
      # @param profile [Profile]
      # @return [Principal]
      def register_principal(client, name:, profile:)
        client.register!(name: name, pow_difficulty: profile.pow_difficulty)
      end

      # Submit a valid KYC attestation for the principal, using the profile's
      # kyc_valid callable.  No-op when profile.kyc_valid is nil.
      #
      # @param client    [Client]
      # @param principal [Principal]
      # @param profile   [Profile]
      # @return [Response, nil]
      def submit_valid_kyc(client, principal, profile)
        return nil unless profile.kyc_valid

        client.kyc(principal, attestation_jws: profile.kyc_valid.call(principal.user_id))
      end

      # Tamper a JWT bearer token by flipping a claim in the payload segment
      # WITHOUT re-signing.  The server MUST reject this with 401.
      #
      # Strategy: base64url-decode the payload, increment a numeric claim or
      # append a sentinel to a string claim, re-encode.  The original signature
      # segment is kept, so it no longer matches the modified payload.
      #
      # @param token [String] original JWT (3 dot-separated base64url segments)
      # @return [String] structurally valid but signature-invalid JWT
      def tamper_token(token)
        header, payload_b64, sig = token.split(".", 3)
        return token if payload_b64.nil?

        # Pad to a multiple of 4 for urlsafe_decode64
        padded  = payload_b64 + ("=" * ((4 - payload_b64.length % 4) % 4))
        claims  = JSON.parse(Base64.urlsafe_decode64(padded))

        # Flip a well-known claim; try several in priority order.
        if claims.key?("role")
          claims["role"] = claims["role"] == "admin" ? "superadmin" : "admin"
        elsif claims.key?("sub")
          claims["sub"] = "#{claims["sub"]}-tampered"
        elsif claims.key?("exp")
          claims["exp"] = (claims["exp"].to_i + 999_999)
        else
          claims["__tamper__"] = true
        end

        new_payload = Base64.urlsafe_encode64(JSON.generate(claims), padding: false)
        [header, new_payload, sig].join(".")
      end

      # Extract rows from a query Response body.
      #
      # @param response [Response]
      # @return [Array<Hash>]
      def rows_from(response)
        body = response.body
        return [] unless body.is_a?(Hash)

        body["rows"] || []
      end
    end
  end
end
