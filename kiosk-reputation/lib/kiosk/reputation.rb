# frozen_string_literal: true

require "kiosk/reputation/version"
require "kiosk/reputation/backends"
require "kiosk/reputation/challenge"
require "kiosk/reputation/factors"
require "kiosk/reputation/policy"
require "kiosk/reputation/policies/rate_and_reputation"

module Kiosk
  # Policy + wire-challenge layer for Kiosk's proof-of-work system.
  #
  # kiosk-reputation is backend-agnostic: concrete PoW algorithms (Equihash —
  # the shipped default, Argon2id legacy, Cuckatoo Cycle, …) are registered by
  # the HOST via {Backends.register} (no PoW gem self-registers on require).
  # This gem does not depend on any PoW gem or kiosk-core.
  #
  # == Key components
  #
  # {Backends}      — algorithm registry (register / fetch / known / reset!)
  # {Challenge}     — stateless, request-bound wire challenge (issue / verify)
  # {Factors}       — immutable bundle of reputation inputs the host supplies
  # {Policy}        — base class (never challenge); providers subclass or replace
  # {Policies::RateAndReputation} — shipped example policy (see its docs)
  #
  # == Anti-DoS invariant (cheap-before-expensive)
  #
  # {Challenge.verify} always performs cheap checks first:
  #   1. HMAC sig + request-binding (constant-time compare)  → :bad_sig
  #   2. Expiry check                                         → :expired
  #   3. Backend .verify (one Equihash proof check)          → :ok / :bad_proof
  #
  # Floods of forged or expired proofs are rejected at step 1/2 without
  # burning an expensive backend evaluation.
  #
  # == Spent-id set (caller responsibility)
  #
  # {Challenge} is stateless. kiosk-server (T3) must maintain a small
  # spent-id set (TTL ≤ challenge[:exp]) to prevent replay of a valid proof.
  module Reputation
  end
end
