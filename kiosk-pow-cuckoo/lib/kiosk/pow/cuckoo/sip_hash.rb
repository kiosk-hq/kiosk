# frozen_string_literal: true

module Kiosk
  module Pow
    module Cuckoo
      # SipHash-2-4 as Cuckatoo uses it: the four keys are NOT XORed with the
      # standard magic constants.
      module SipHash
        MASK64 = (1 << 64) - 1
        private_constant :MASK64

        def self.digest(keys, nonce)
          state = keys.dup
          state[3] ^= nonce
          2.times { round(state) }
          state[0] ^= nonce
          state[2] ^= 0xff
          4.times { round(state) }
          state.reduce(:^)
        end

        # One SipRound as two half rounds. Each half updates two independent
        # lane pairs: (a, b) and (c, d).
        def self.round(state)
          half_round(state, [0, 1, 2, 3], 13, 16)
          half_round(state, [2, 1, 0, 3], 17, 21)
        end

        def self.half_round(state, lanes, rotate_b, rotate_d)
          a, b, c, d = lanes
          add_rotate_xor(state, a, b, rotate_b)
          state[a] = rotl64(state[a], 32)
          add_rotate_xor(state, c, d, rotate_d)
        end

        # Adds lane `src` into lane `dst`, then rotates `src` and XORs `dst` into it.
        def self.add_rotate_xor(state, dst, src, bits)
          state[dst] = (state[dst] + state[src]) & MASK64
          state[src] = rotl64(state[src], bits) ^ state[dst]
        end

        def self.rotl64(word, bits) = ((word << bits) | (word >> (64 - bits))) & MASK64

        private_class_method :round, :half_round, :add_rotate_xor, :rotl64
      end
    end
  end
end
