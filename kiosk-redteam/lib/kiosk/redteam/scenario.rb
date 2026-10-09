# frozen_string_literal: true

require "json"
require "base64"

module Kiosk
  module Redteam
    # Base class for adversarial scenarios. Subclasses implement #call and
    # return a Verdict: blocked when the origin refused the attack, skipped
    # when the profile lacks the surface the scenario needs.
    class Scenario
      attr_reader :name
      attr_reader :category
      attr_reader :description

      def initialize(name:, category:, description:)
        @name        = name
        @category    = category
        @description = description
      end

      def call(client, profile) # rubocop:disable Lint/UnusedMethodArgument
        raise NotImplementedError, "#{self.class}#call is not implemented"
      end

      private

      def skip_verdict(reason)
        Verdict.new(blocked: false, skipped: true, status: 0, detail: "SKIP — #{reason}")
      end

      # +expect+ / +expect_code+ name the gate that must refuse; with neither,
      # any status or code Kiosk::Redteam.blocked? accepts counts.
      def verdict_from(response, expect: nil, expect_code: nil, detail: nil)
        if expect.nil? && expect_code.nil?
          stall = payment_required_stall(response)
          return stall if stall

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
        misses << "HTTP 402 is conclusive only with an explicit expect_code — " \
                  "#{Kiosk::Redteam::PAYMENT_REQUIRED_CODES.keys.join("/")} all ride that status" \
          if response.status == 402 && expect_code.nil?

        Verdict.new(
          blocked: misses.empty?,
          skipped: false,
          status:  response.status,
          detail:  misses.empty? ? "" : "#{detail || "attack was not refused by the named gate"} " \
                                        "[#{misses.join("; ")}; got HTTP #{response.status} " \
                                        "code=#{code.inspect}, body=#{response.body.inspect}]",
        )
      end

      # A 402 means the attack was not evaluated: neither blocked nor skipped, so it cannot pass silently.
      def payment_required_stall(response, step: nil)
        reason = Kiosk::Redteam.payment_required_reason(response)
        return nil unless reason

        Verdict.new(
          blocked: false,
          skipped: false,
          status:  response.status,
          detail:  "COULD NOT TEST: #{step || "the attack under test"} was answered #{reason}. " \
                   "That is neither a refusal of this attack nor a breach — nothing was proved " \
                   "either way. A provider that means a payment gate HERE must have the scenario " \
                   "name the code it accepts (verdict_from expect_code:).",
        )
      end

      # A failed setup step must not let a later refusal from another gate pass as this one's.
      def setup_failure(response, step:, because:)
        return nil if response.nil? || response.status == 200

        Verdict.new(
          blocked: false,
          skipped: false,
          status:  response.status,
          detail:  "SETUP FAILED: #{step} returned HTTP #{response.status} " \
                   "#{response.body.inspect}. #{because}",
        )
      end

      def error_code(response)
        Kiosk::Redteam.error_code(response)
      end

      def submit_valid_kyc(client, principal, profile)
        return nil unless profile.kyc_valid

        client.kyc(principal, attestation_jws: profile.kyc_valid.call(principal.user_id))
      end

      # Changes a payload claim and keeps the original signature.
      def tamper_token(token)
        header, payload_b64, sig = token.split(".", 3)
        return token if payload_b64.nil?

        padded  = payload_b64 + ("=" * ((4 - payload_b64.length % 4) % 4))
        claims  = JSON.parse(Base64.urlsafe_decode64(padded))

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

      # A query answers a bare Array (§8.2); the `rows` envelope is read too so an
      # older origin's rows are not mistaken for an empty, unleaked list.
      def rows_from(response)
        body = response.body
        return body if body.is_a?(Array)
        return [] unless body.is_a?(Hash)

        rows = body["rows"]
        rows.is_a?(Array) ? rows : []
      end
    end
  end
end
