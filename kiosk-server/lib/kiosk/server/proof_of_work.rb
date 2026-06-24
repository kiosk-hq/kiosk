# frozen_string_literal: true

require "digest"

module Kiosk
  module Server
    # Stateless hashcash-style Proof-of-Work guard for agent registration.
    #
    # A registering agent must compute a `pow` nonce such that:
    #
    #   SHA256("#{public_key_pem}.#{pow}")  has ≥ `difficulty` leading zero BITS
    #
    # The agent's own public key PEM is the unique salt — no server-stored
    # challenge needed.  `difficulty = 0` (the default) bypasses the check
    # entirely, preserving Plan 2/3 open-registration behaviour.
    #
    # Leading-zero-bit count is measured from the MSB of the first byte of the
    # raw (binary) digest — i.e. standard hashcash bit-difficulty.
    module ProofOfWork
      module_function

      # Count the number of leading zero BITS in a binary digest string.
      #
      # @param bytes [String] raw binary bytes (e.g. Digest::SHA256.digest output)
      # @return [Integer] number of leading zero bits (MSB-first)
      def leading_zero_bits(bytes)
        return 0 if bytes.empty?

        count = 0
        bytes.each_byte do |b|
          if b == 0
            count += 8
          else
            # Count how many leading zero bits this byte has.
            # 0x80 = 10000000 → 0 leading zeros
            # 0x40 = 01000000 → 1
            # 0x20 = 00100000 → 2  etc.
            bit = 7
            bit -= 1 while bit >= 0 && b[bit] == 0
            # `bit` is now the index (0-based from LSB) of the highest set bit.
            count += (7 - bit)
            break
          end
        end
        count
      end

      # Return true iff the supplied `pow` satisfies `difficulty` leading zero
      # bits in SHA256("#{public_key_pem}.#{pow}").
      #
      # @param public_key_pem [String]
      # @param pow            [String] the nonce the client computed
      # @param difficulty     [Integer] required leading zero bits (0 = always valid)
      # @return [Boolean]
      def valid?(public_key_pem:, pow:, difficulty:)
        return true if difficulty <= 0

        digest = Digest::SHA256.digest("#{public_key_pem}.#{pow}")
        leading_zero_bits(digest) >= difficulty
      end
    end
  end
end
