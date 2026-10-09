# frozen_string_literal: true

require "json"
require "open3"

require_relative "../equihash"

module Kiosk
  module Pow
    module Equihash
      class SolverError < StandardError; end

      # Client side only: required separately so an operator verifying proofs never loads `open3`.
      # Needs python3 + numpy on PATH (see README, "Solver (Python + numpy)").
      # @param challenge [Hash] the challenge object exactly as the provider issued it
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
