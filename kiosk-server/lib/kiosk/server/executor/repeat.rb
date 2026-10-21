# frozen_string_literal: true

module Kiosk
  module Server
    class Executor
      # A `pay` whose mandates, or another live pair for the same checkout, came before (§11.6).
      module Repeat
        private

        # The identical pair, presented before. Settled: its settlement. Neither
        # settled nor declined: the pair, to capture again. Anything else is a conflict.
        def repeat(chain)
          row = recorded_chain(chain)
          raise Errors::Conflict.new('mandate already processed', hint: Pay::CONFLICT_HINT) if row.nil? || row['declined_at']
          return stored_settlement(chain, row) if row['settlement_id']

          chain.checkout_row = row.fetch('checkout_row')
          chain.repeat = true
          chain
        end

        def recorded_chain(chain)
          return nil if chain.checkout.nil? || chain.payment.nil?

          row = nil
          SessionContext.open(connection: connection, identity: identity) { row = chain_record(chain) }
          row
        end

        def stored_settlement(chain, row)
          settled = { psp_reference: row.fetch('psp_reference'), settled_amount_cents: row.fetch('settled_amount_cents').to_i,
                      network_confirmation_id: row['network_confirmation_id'] }
          settlement_result(chain, row.fetch('settlement_id'), settled, row.fetch('currency'))
        end

        # A refusal under which no money moved: the checkout stops counting against the spending cap.
        def decline(chain)
          SessionContext.open(connection: connection, identity: identity) { decline_checkout(chain.checkout_row) }
        end
      end
    end
  end
end
