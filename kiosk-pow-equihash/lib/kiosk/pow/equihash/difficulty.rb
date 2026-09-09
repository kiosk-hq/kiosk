# frozen_string_literal: true

module Kiosk
  module Pow
    module Equihash
      # The operator's difficulty knob. `KIOSK_POW_DIFFICULTY` picks the (n, k)
      # an origin prices its Equihash-tolled verbs at, so an ordinary hosted app
      # can stay poke-friendly while one that wants the DoS shield to be
      # tangible charges the shipped default.
      #
      # Cost is driven by n_div = n/(k+1); bench/README.md has the measured grid.
      #
      #   low  (default) — n=96, k=5. Sub-second reference solve, ~tens of MB.
      #                    Unset or unrecognised ALWAYS lands here, so CI and
      #                    local flows never pay the heavy toll.
      #   high           — {DEFAULT_N} / {DEFAULT_K}, this gem's shipped
      #                    default: ~1.3 GiB peak, and ~10 s p50 on the
      #                    reference numpy solver MEASURED ON ONE M-SERIES
      #                    LAPTOP CORE — the only hardware it has ever been
      #                    measured on (bench/README.md). That peak is THAT
      #                    solver's sorted-nonce table, so it does not vary with
      #                    the host — but it is not a floor these params impose
      #                    on every solver either: a memory-optimised solver
      #                    trades the table for time. The seconds are that
      #                    machine class.
      #
      # Two levels rather than a free (n, k) pair, because the pair an origin
      # advertises is also the pair every honest client must pay: a knob that
      # can be set to anything is a knob that can price a verb out of reach by
      # accident.
      module Difficulty
        # Params, not solvers: the shipped solver clears both levels; only the
        # wall-clock and RAM cost differ. `high` is read off {DEFAULT_N} and
        # {DEFAULT_K} rather than written out again, so the heavy level and the
        # gem's own default cannot drift apart.
        LEVELS = {
          "low"  => { n: 96, k: 5 }.freeze,
          "high" => { n: DEFAULT_N, k: DEFAULT_K }.freeze,
        }.freeze

        # The level an unset or unrecognised `KIOSK_POW_DIFFICULTY` lands on.
        DEFAULT = "low"

        module_function

        # @return ["low", "high"] the active level, from `KIOSK_POW_DIFFICULTY`.
        #   Anything unrecognised, unset included, falls back to {DEFAULT}.
        def level
          lvl = ENV["KIOSK_POW_DIFFICULTY"].to_s.strip.downcase
          LEVELS.key?(lvl) ? lvl : DEFAULT
        end

        # @return [Hash] Equihash params `{ n:, k: }` for the active level, in
        #   the shape {Kiosk::Pow::Equihash.params} returns.
        def params
          LEVELS.fetch(level)
        end

        # @return [Boolean] true when the toll is heavy enough to warrant a
        #   "beware" banner in the origin's discovery document.
        def high?
          level == "high"
        end

        # The notice for a discovery document's owner block, so an assistant
        # meeting this origin learns the toll is expensive BEFORE it spends ten
        # seconds and a gigabyte finding out.
        #
        # @return [String, nil] nil at "low": there is nothing to warn about.
        def pow_notice
          return nil unless high?

          p = params
          "beware: memory- and CPU-intensive proof-of-work — this provider prices " \
            "registration/browsing with Equihash n=#{p[:n]} k=#{p[:k]} " \
            "(~1.3 GiB per proof; ~10 s on a reference numpy solver, measured on " \
            "one M-series laptop core). This is " \
            "deliberate: the toll is the DoS shield, and it costs the client, not " \
            "the provider. Use the bundled kiosk-pow-equihash solver."
        end
      end
    end
  end
end
