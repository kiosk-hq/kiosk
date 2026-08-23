# frozen_string_literal: true

# Per-demo PoW difficulty knob: KIOSK_POW_DIFFICULTY picks the Equihash (n, k)
# a demo's register/browse toll is priced at, so most hosted apps stay
# poke-friendly while the showcase one makes the DoS shield tangible.
#
# Cost is driven by n_div = n/(k+1); kiosk-pow-equihash/bench/README.md has the
# measured grid.
#
#   low  (default) — n=96, k=5. Sub-second reference solve, ~tens of MB.
#                    Unset or unrecognised ALWAYS lands here, so CI and local
#                    flows never pay the heavy toll.
#   high           — n=168, k=7, the shipped kiosk-pow-equihash default:
#                    ~10 s p50 / ~1.3 GiB peak on a reference numpy solver.
#                    Any operator may set it; the hosted deploy sets it on
#                    atablefor alone (deploy/env/*.env.example), and that demo's
#                    discovery owner block then carries the "beware" notice.
module PowDifficulty
  # Params, not solvers: the shipped solver clears both levels; only the
  # wall-clock and RAM cost differ.
  LEVELS = {
    "low"  => { n: 96,  k: 5 }.freeze,
    "high" => { n: 168, k: 7 }.freeze,
  }.freeze

  DEFAULT = "low"

  module_function

  # "low" | "high", from KIOSK_POW_DIFFICULTY. Anything unrecognised, unset
  # included, falls back to "low".
  def level
    lvl = ENV["KIOSK_POW_DIFFICULTY"].to_s.strip.downcase
    LEVELS.key?(lvl) ? lvl : DEFAULT
  end

  # Equihash params Hash `{ n:, k: }` for the active level.
  def params
    LEVELS.fetch(level)
  end

  # True when the toll is heavy enough to warrant a "beware" banner in discovery.
  def high?
    level == "high"
  end

  # The notice for the discovery document's owner block. nil at "low": there is
  # nothing to warn about.
  def pow_notice
    return nil unless high?

    p = params
    "beware: memory- and CPU-intensive proof-of-work — this provider prices " \
      "registration/browsing with Equihash n=#{p[:n]} k=#{p[:k]} " \
      "(~10s and ~1.3 GiB per proof on a reference solver). This is " \
      "deliberate: the toll is the DoS shield, and it costs the client, not " \
      "the provider. Use the bundled kiosk-pow-equihash solver."
  end
end
