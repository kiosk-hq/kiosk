# frozen_string_literal: true

module Kiosk
  module Redteam
    # Builds the Verdict a Scenario returns. Mixed into Scenario as private methods.
    module Verdicts
      private

      def skip_verdict(reason)
        Verdict.new(blocked: false, skipped: true, status: 0, detail: "SKIP — #{reason}")
      end

      # The first profile field that is unset, as a skip verdict; nil when every field is set.
      def skip_unless(profile, reasons)
        _field, reason = reasons.find { |field, _| !profile.public_send(field) }
        reason && skip_verdict(reason)
      end

      def blocked_verdict(status, detail = '')
        Verdict.new(blocked: true, skipped: false, status: status, detail: detail)
      end

      def breach_verdict(status, detail)
        Verdict.new(blocked: false, skipped: false, status: status, detail: detail)
      end

      # +expect+ / +expect_code+ name the gate that must refuse; with neither,
      # any status or code Kiosk::Redteam.blocked? accepts counts.
      def verdict_from(response, expect: nil, expect_code: nil, detail: nil)
        return any_gate_verdict(response, detail) if expect.nil? && expect_code.nil?

        misses = gate_misses(response, expect, expect_code)
        return blocked_verdict(response.status) if misses.empty?

        breach_verdict(response.status,
                       "#{detail || 'attack was not refused by the named gate'} " \
                       "[#{misses.join('; ')}; got HTTP #{response.status} " \
                       "code=#{error_code(response).inspect}, body=#{response.body.inspect}]")
      end

      def any_gate_verdict(response, detail)
        stall = payment_required_stall(response)
        return stall if stall
        return blocked_verdict(response.status) if Kiosk::Redteam.blocked?(response)

        breach_verdict(response.status, detail || "HTTP #{response.status}: #{response.body.inspect}")
      end

      def gate_misses(response, expect, expect_code)
        [
          status_miss(response.status, expect),
          code_miss(error_code(response), expect_code),
          ('5xx is never a block' if response.status >= 500),
          (unpinned_payment_miss if response.status == 402 && expect_code.nil?)
        ].compact
      end

      def status_miss(status, expect)
        return nil if expect.nil? || Array(expect).include?(status)

        "want status #{Array(expect).join('/')}"
      end

      def code_miss(code, expect_code)
        return nil if expect_code.nil? || Array(expect_code).include?(code)

        "want error.code #{Array(expect_code).map(&:inspect).join('/')}"
      end

      def unpinned_payment_miss
        'HTTP 402 is conclusive only with an explicit expect_code — ' \
          "#{Kiosk::Redteam::PAYMENT_REQUIRED_CODES.keys.join('/')} all ride that status"
      end

      # A 402 means the attack was not evaluated: neither blocked nor skipped, so it cannot pass silently.
      def payment_required_stall(response, step: nil)
        reason = Kiosk::Redteam.payment_required_reason(response)
        return nil unless reason

        breach_verdict(
          response.status,
          "COULD NOT TEST: #{step || 'the attack under test'} was answered #{reason}. " \
          'That is neither a refusal of this attack nor a breach — nothing was proved ' \
          'either way. A provider that means a payment gate HERE must have the scenario ' \
          'name the code it accepts (verdict_from expect_code:).'
        )
      end

      # A failed setup step must not let a later refusal from another gate pass as this one's.
      def setup_failure(response, step:, because:)
        return nil if response.nil? || response.status == 200

        breach_verdict(response.status,
                       "SETUP FAILED: #{step} returned HTTP #{response.status} " \
                       "#{response.body.inspect}. #{because}")
      end

      def error_code(response)
        Kiosk::Redteam.error_code(response)
      end
    end
  end
end
