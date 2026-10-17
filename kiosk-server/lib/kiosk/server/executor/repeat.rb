# frozen_string_literal: true

module Kiosk
  module Server
    class Executor
      # A `pay` whose chain was presented before (§11.6).
      module Repeat
        private

        # A chain presented before. Settled: its settlement. Neither settled nor
        # declined: the chain, to capture again. Anything else is a conflict.
        def repeat(chain)
          row = recorded_chain(chain)
          raise Errors::Conflict.new('mandate already processed', hint: Pay::CONFLICT_HINT) if row.nil? || row['declined_at']
          return stored_settlement(row) if row['settlement_id']

          chain.cart_row = row.fetch('cart_row')
          chain.repeat   = true
          chain
        end

        def recorded_chain(chain)
          return nil if chain.intent.nil? || chain.cart.nil? || chain.payment.nil?

          row = nil
          SessionContext.open(connection: connection, identity: identity) { row = chain_record(chain) }
          row
        end

        def stored_settlement(row)
          settlement_result(row.fetch('settlement_id'), row.fetch('psp_reference'),
                            row.fetch('settled_amount_cents').to_i, row.fetch('currency'))
        end

        # A refusal under which no money moved: the cart stops counting against the spending cap.
        def decline(chain)
          SessionContext.open(connection: connection, identity: identity) { decline_cart(chain.cart_row) }
        end
      end
    end
  end
end
