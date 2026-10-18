# frozen_string_literal: true

module Kiosk
  module Server
    class Executor
      # The assistant's spending cap, checked at pay time.
      module SpendingCap
        private

        # A nil seam or a nil cap means uncapped. Runs in the transaction that
        # persists the cart, under a per-assistant lock, so two concurrent pays
        # see each other: the second counts the first's cart as in flight. A
        # cart already recorded is a repeat and adds nothing.
        def enforce_spending_cap!(cart)
          cap = Kiosk.configuration.spending_cap&.call(agent_id: identity.agent_id)
          return if cap.nil? # this assistant is uncapped

          lock_assistant_payments!(identity.agent_id)
          refuse_over_cap!(cap.to_i, cart) unless cart_recorded?(cart)
        end

        def refuse_over_cap!(cap, cart)
          window_days = Kiosk.configuration.spending_cap_window_days
          spent = spent_in_window(cart, window_days)
          return if spent + cart.total_amount_cents.to_i <= cap

          raise Errors::SpendingCapExceeded.new('assistant spending cap exceeded', hint: cap_hint(cap, spent, window_days, cart))
        end

        # One tally per currency: cents are not fungible across currencies. One
        # statement, so a settlement committed between two reads is counted once.
        def spent_in_window(cart, window_days)
          binds = spent_binds(identity.agent_id, cart.currency, window_days)
          sql = "SELECT (#{settled_sql(window_days)}) + (#{in_flight_sql}) AS total"
          connection.exec_query(sql, 'Kiosk spent total', binds).to_a.first.fetch('total').to_i
        end

        def cap_hint(cap, spent, window_days, cart)
          window_note = window_days ? " in the last #{window_days.to_i} day(s)" : ''
          "cap #{cap} cents; #{spent} already settled or in flight#{window_note}; " \
            "this charge is #{cart.total_amount_cents.to_i}"
        end

        # Settled cents for this agent in one currency, case-folded on both sides
        # so `eur` and `EUR` are one tally. No window means no predicate; the day count is a bind.
        def settled_sql(window_days)
          window = window_days ? 'AND settled_at >= now() - make_interval(days => $3)' : ''
          <<~SQL.squish
            SELECT COALESCE(SUM(settled_amount_cents), 0) AS total
            FROM #{Kiosk.configuration.schema}.settlements
            WHERE agent_id = $1 AND lower(btrim(currency)) = $2 #{window}
          SQL
        end

        # Carts of this agent whose mandate is live, that have no settlement and
        # were not declined: a capture may still run for each.
        def in_flight_sql
          schema = Kiosk.configuration.schema
          <<~SQL.squish
            SELECT COALESCE(SUM(c.total_amount_cents), 0) AS total
            FROM #{schema}.cart_mandates c
            WHERE c.agent_id = $1 AND lower(btrim(c.currency)) = $2 AND c.expires_at > now()
              AND c.declined_at IS NULL
              AND NOT EXISTS (SELECT 1 FROM #{schema}.settlements s WHERE s.cart_mandate_id = c.id)
          SQL
        end

        # The agent, the canonical currency and, with a window, its day count.
        def spent_binds(agent_id, currency, window_days)
          binds = [agent_id, MandateVerifier.canonical_currency(currency)]
          window_days ? binds << window_days.to_i : binds
        end

        def cart_recorded?(cart)
          sql = "SELECT 1 FROM #{Kiosk.configuration.schema}.cart_mandates WHERE user_id = $1 AND mandate_id = $2"
          connection.exec_query(sql, 'Kiosk cart recorded', [cart.user_id, cart.id]).any?
        end

        # Held to the end of the transaction; an advisory lock needs no grant on any table.
        def lock_assistant_payments!(agent_id)
          connection.exec_query('SELECT pg_advisory_xact_lock(hashtextextended($1, 0))',
                                'Kiosk spending cap lock', [agent_id.to_s])
        end
      end
    end
  end
end
