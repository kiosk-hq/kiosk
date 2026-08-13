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
    # skip Verdict (blocked: false, skipped: true, detail: "SKIP — …") — a
    # distinct third state, NOT a pass: it does not count towards the blocked
    # count, and the demo's expected-applicable assertion catches a skip that
    # was not meant to happen.  (This paragraph described the pre-fix
    # `blocked: true` skip long after {#skip_verdict} stopped returning one —
    # see the gem CHANGELOG's "a skipped scenario reports a real skipped
    # state instead of a pass".)
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

      # Wrap a server Response into a Verdict.
      #
      # A scenario that knows WHICH gate must fire says so with +expect+ /
      # +expect_code+: only those status(es) and denial code(s) count as a
      # genuine refusal of THIS attack, and anything else — a refusal from an
      # unrelated gate, a mis-routed 404, a crash — is not a pass. The failing
      # detail names what was demanded and what came back, so a verdict that
      # moves is auditable without re-running the battery by hand.
      #
      # With neither given, the verdict delegates to {Kiosk::Redteam.blocked?},
      # which admits ANY of 401/402/403 or any recognised denial code. That is
      # honest ONLY for a scenario whose attack several different gates may
      # legitimately refuse; every such call site states which gates it admits.
      #
      # 5xx is never blocked, whatever is asked for — a crash cannot masquerade
      # as enforcement (see {Kiosk::Redteam.blocked?}).
      #
      # @param response    [Response]
      # @param expect      [Integer, Array<Integer>, nil] status(es) that count
      #   as a refusal of this attack; nil admits the whole blocked? set.
      # @param expect_code [String, Array<String>, nil] `body["error"]["code"]`
      #   value(s) that count; nil does not inspect the code.
      # @param detail      [String] extra context to append on breach
      # @return [Verdict]
      def verdict_from(response, expect: nil, expect_code: nil, detail: nil)
        if expect.nil? && expect_code.nil?
          blocked = Kiosk::Redteam.blocked?(response)
          return Verdict.new(
            blocked: blocked,
            skipped: false,
            status:  response.status,
            detail:  blocked ? "" : (detail || "HTTP #{response.status}: #{response.body.inspect}"),
          )
        end

        code   = error_code(response)
        misses = []
        misses << "want status #{Array(expect).join("/")}" if expect && !Array(expect).include?(response.status)
        misses << "want error.code #{Array(expect_code).map(&:inspect).join("/")}" \
          if expect_code && !Array(expect_code).include?(code)
        misses << "5xx is never a block" if response.status >= 500

        Verdict.new(
          blocked: misses.empty?,
          skipped: false,
          status:  response.status,
          detail:  misses.empty? ? "" : "#{detail || "attack was not refused by the named gate"} " \
                                        "[#{misses.join("; ")}; got HTTP #{response.status} " \
                                        "code=#{code.inspect}, body=#{response.body.inspect}]",
        )
      end

      # Read `body["error"]["code"]` defensively — `body["error"]` may be a
      # plain String, and the body itself may not be a Hash at all.
      #
      # @param response [Response]
      # @return [String, nil]
      def error_code(response)
        body = response.body
        return nil unless body.is_a?(Hash)

        error = body["error"]
        error.is_a?(Hash) ? error["code"] : nil
      end

      # Register a principal.  Any PoW solving is driven entirely by the
      # server's 402 Equihash challenges, not by profile.pow_difficulty:
      # that integer is INERT — accepted but never read by the Client (see
      # {Client#register_raw}).  It is threaded through only so callers don't
      # have to change; scenarios read it directly to decide applicability.
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
