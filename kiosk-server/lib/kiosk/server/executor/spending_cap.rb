# frozen_string_literal: true

module Kiosk
  module Server
    class Executor
      # The assistant's spending cap: the most one `pay` may charge, checked before capture.
      module SpendingCap
        private

        # A nil seam or a nil cap means uncapped. A cap allows no payment in
        # another currency. A checkout mandate already recorded is a repeat: the
        # first `pay` of that checkout passed this check.
        def enforce_spending_cap!(checkout)
          cap = Kiosk.configuration.spending_cap&.call(agent_id: identity.agent_id)
          return if cap.nil? || checkout_recorded?(checkout)

          refuse_other_currency!(cap.fetch(:currency), checkout)
          refuse_over_cap!(cap.fetch(:amount_cents).to_i, checkout)
        end

        def refuse_other_currency!(cap_currency, checkout)
          cap_code = MandateVerifier.canonical_currency(cap_currency)
          return if cap_code == checkout.currency

          raise Errors::SpendingCapExceeded.new('assistant spending cap is in another currency',
                                                hint: "the cap is in #{cap_code.upcase}; this charge is in #{checkout.currency.upcase}")
        end

        def refuse_over_cap!(cap, checkout)
          return if checkout.total_amount_cents <= cap

          raise Errors::SpendingCapExceeded.new('assistant spending cap exceeded',
                                                hint: "one payment may charge #{cap} cents at most; this charge is #{checkout.total_amount_cents} cents")
        end

        def checkout_recorded?(checkout)
          sql = "SELECT 1 FROM #{Kiosk.configuration.schema}.kiosk_checkout_mandates WHERE user_id = $1 AND reference = $2"
          connection.exec_query(sql, 'Kiosk checkout mandate recorded', [checkout.user_id, checkout.reference]).any?
        end
      end
    end
  end
end
