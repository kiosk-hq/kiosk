# frozen_string_literal: true

require "json"
require "open3"

require_relative "../equihash"

module Kiosk
  module Pow
    module Equihash
      # Raised by {Kiosk::Pow::Equihash.solve} when the bundled solver cannot
      # answer a challenge.
      class SolverError < StandardError; end

      # Solve ONE challenge with the reference solver this gem packages, and
      # return the proof `nonce` in the shape the `Kiosk-PoW` header carries.
      #
      #   require "kiosk/pow/equihash/solver"
      #   proofs = challenges.map { |c| { challenge: c, nonce: Equihash.solve(c) } }
      #
      # It lives here rather than in each caller because the solver's location
      # is this gem's to know: {solver_path} resolves inside the installed
      # package, where a checkout-relative path does not exist.
      #
      # THIS FILE IS REQUIRED SEPARATELY, AND THAT SEPARATION IS THE POINT.
      # `kiosk/pow/equihash` is what an OPERATOR loads — it verifies a proof on
      # an unauthenticated `POST /auth/register`, and nothing on that path may
      # be able to spawn a process. Solving is the CLIENT's half of the same
      # algorithm: an assistant, a demo flow driver, an adversarial harness.
      # A caller that wants it says so, and a provider that never asks never
      # loads `open3` at all.
      #
      # Needs python3 + numpy on PATH (see README, "Solver (Python + numpy)").
      # The `challenge` is passed through verbatim, so the parameters solved
      # against are the ones the SERVER minted — never a pair the caller typed.
      #
      # @param challenge [Hash] a challenge object as the provider issued it
      # @return [Hash] `{ "indices" => Array<Integer>, "header_nonce" => Integer }`
      # @raise [SolverError] when the solver exits non-zero or reports an error
      def self.solve(challenge)
        out, status = Open3.capture2("python3", solver_path, JSON.generate(challenge))
        raise SolverError, "solve.py exited non-zero: #{out}" unless status.success?

        parsed = JSON.parse(out)
        raise SolverError, "solve.py error: #{parsed["error"]}" if parsed.key?("error")

        { "indices" => parsed.fetch("indices"), "header_nonce" => parsed.fetch("header_nonce") }
      end
    end
  end
end
