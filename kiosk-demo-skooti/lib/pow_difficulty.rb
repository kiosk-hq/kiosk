# frozen_string_literal: true

# Per-demo PoW difficulty knob (T-032, HOSTED-DEMOS decision).
#
# Reads ENV["KIOSK_POW_DIFFICULTY"] once and maps it to concrete Equihash
# (n, k) params so a demo's register/browse PoW can be poke-friendly on most
# hosted apps but genuinely memory- and CPU-intensive on a couple of them —
# making the DoS-shield toll TANGIBLE to an HN reader or their agent.
#
# Levels (Equihash cost is driven by n_div = n/(k+1); see
# kiosk-pow-equihash/bench/README.md for the measured grid):
#
#   low  (default) — n=96, k=5  → sub-second reference solve, ~tens of MB.
#                    Poke-friendly. Local `demo:setup`/CI stay fast; unset
#                    KIOSK_POW_DIFFICULTY ALWAYS resolves here, so CI never
#                    pays the heavy toll and never hangs.
#   high           — n=168, k=7 → the shipped kiosk-pow-equihash default:
#                    ~10 s p50 / ~1.3 GiB peak on a reference (numpy) solver
#                    — a real memory+CPU toll a poker feels first-hand. Used
#                    on skooti + atablefor in the hosted deploy ONLY.
#
# This helper is OPT-IN and defaults low: a demo that never sets
# KIOSK_POW_DIFFICULTY=high behaves EXACTLY as before this knob existed.
module PowDifficulty
  # Equihash params per level. Values, not solvers — the shipped solver
  # (kiosk-pow-equihash/solve.py) clears both; only the wall-clock/RAM cost
  # differs.
  LEVELS = {
    "low"  => { n: 96,  k: 5 }.freeze,
    "high" => { n: 168, k: 7 }.freeze,
  }.freeze

  DEFAULT = "low"

  module_function

  # The active difficulty level ("low" | "high"), from KIOSK_POW_DIFFICULTY.
  # Anything unrecognised (incl. unset/empty) falls back to "low" — the safe
  # default that keeps CI and local flows fast.
  def level
    lvl = ENV["KIOSK_POW_DIFFICULTY"].to_s.strip.downcase
    LEVELS.key?(lvl) ? lvl : DEFAULT
  end

  # Equihash params Hash `{ n:, k: }` for the active level.
  def params
    LEVELS.fetch(level)
  end

  # True when the active level is a genuinely heavy (memory+CPU-intensive)
  # PoW — the signal that warrants a "beware" banner in discovery.
  def high?
    level == "high"
  end

  # An honest, human/agent-readable notice for the discovery document's owner
  # block when the toll is heavy. nil at "low" (no banner — nothing to warn).
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
