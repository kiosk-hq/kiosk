# frozen_string_literal: true

module Kiosk
  module Pow
    module Equihash
      # BLAKE2b-256 (RFC 7693): unkeyed, 32-byte digest. Pure Ruby, so the gem
      # has no dependencies. kiosk-pow-cuckoo carries the same code.
      module Blake2b
        MASK64 = (1 << 64) - 1
        BLOCK_BYTES = 128

        # Parameter block word 0: outlen=32, keylen=0, fanout=1, depth=1.
        PARAM_BLOCK = 0x0000_0000_0101_0020

        IV = [
          0x6a09e667f3bcc908, 0xbb67ae8584caa73b,
          0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
          0x510e527fade682d1, 0x9b05688c2b3e6c1f,
          0x1f83d9abfb41bd6b, 0x5be0cd19137e2179
        ].freeze

        SIGMA = [
          [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
          [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
          [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
          [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
          [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
          [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
          [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
          [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
          [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
          [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0]
        ].freeze

        # The lanes [a, b, c, d] of the eight G calls in one round: four columns, then four diagonals.
        ROUND_LANES = [
          [0, 4, 8, 12], [1, 5, 9, 13], [2, 6, 10, 14], [3, 7, 11, 15],
          [0, 5, 10, 15], [1, 6, 11, 12], [2, 7, 8, 13], [3, 4, 9, 14]
        ].freeze

        private_constant :MASK64, :BLOCK_BYTES, :PARAM_BLOCK, :IV, :SIGMA, :ROUND_LANES

        def self.digest256(input)
          data  = input.b
          chain = IV.dup
          chain[0] ^= PARAM_BLOCK
          blocks(data).each { |words, counter, last| compress(chain, words, counter, last) }
          chain[0, 4].pack('Q<4')
        end

        # Each message block as [16 words, byte counter, last?]. An empty input is one zero block.
        def self.blocks(data)
          return [[[0] * 16, 0, true]] if data.empty?

          count = (data.bytesize + BLOCK_BYTES - 1) / BLOCK_BYTES
          Array.new(count) do |index|
            last    = index == count - 1
            offset  = index * BLOCK_BYTES
            counter = last ? data.bytesize : offset + BLOCK_BYTES
            [data.byteslice(offset, BLOCK_BYTES).ljust(BLOCK_BYTES, "\x00").unpack('Q<16'), counter, last]
          end
        end

        def self.compress(chain, words, counter, last)
          work = chain + IV
          work[12] ^= counter & MASK64
          work[14] ^= MASK64 if last
          12.times { |round| mix_round(work, words, SIGMA[round % 10]) }
          8.times { |i| chain[i] ^= work[i] ^ work[i + 8] }
        end

        def self.mix_round(work, words, sigma)
          ROUND_LANES.each_with_index do |lanes, i|
            mix(work, lanes, words[sigma[2 * i]], 32, 24)
            mix(work, lanes, words[sigma[(2 * i) + 1]], 16, 63)
          end
        end

        # One half of the G function: add a message word, then two add-xor-rotate steps.
        def self.mix(work, lanes, word, rotate_d, rotate_b)
          a, b, c, d = lanes
          add(work, a, b, word)
          xor_rotate(work, d, a, rotate_d)
          add(work, c, d, 0)
          xor_rotate(work, b, c, rotate_b)
        end

        def self.add(work, dst, src, word)
          work[dst] = (work[dst] + work[src] + word) & MASK64
        end

        def self.xor_rotate(work, dst, src, bits)
          work[dst] = rotr64(work[dst] ^ work[src], bits)
        end

        def self.rotr64(word, bits) = ((word >> bits) | (word << (64 - bits))) & MASK64

        private_class_method :blocks, :compress, :mix_round, :mix, :add, :xor_rotate, :rotr64
      end
    end
  end
end
