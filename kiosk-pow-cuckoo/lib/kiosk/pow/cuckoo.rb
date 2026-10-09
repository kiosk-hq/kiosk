# frozen_string_literal: true

require "kiosk/pow/cuckoo/version"

module Kiosk
  module Pow
    # Cuckatoo Cycle proof-of-work verifier, clean-room from Tromp's spec.
    # The proof `nonce` is { header_nonce: <u32>, cycle: [42 ascending edge indices] };
    # the solver is `solve_cuckoo.py`, packaged beside this file.
    module Cuckoo
      NAME = "cuckatoo"

      MASK64 = (1 << 64) - 1
      private_constant :MASK64

      # BLAKE2b-256, sequential mode, no key (https://www.blake2.net/blake2.pdf).
      BLAKE2B_IV = [
        0x6a09e667f3bcc908, 0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
        0x510e527fade682d1, 0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
      ].freeze
      private_constant :BLAKE2B_IV

      BLAKE2B_SIGMA = [
        [ 0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15],
        [14, 10,  4,  8,  9, 15, 13,  6,  1, 12,  0,  2, 11,  7,  5,  3],
        [11,  8, 12,  0,  5,  2, 15, 13, 10, 14,  3,  6,  7,  1,  9,  4],
        [ 7,  9,  3,  1, 13, 12, 11, 14,  2,  6,  5, 10,  4,  0, 15,  8],
        [ 9,  0,  5,  7,  2,  4, 10, 15, 14,  1, 11, 12,  6,  8,  3, 13],
        [ 2, 12,  6, 10,  0, 11,  8,  3,  4, 13,  7,  5, 15, 14,  1,  9],
        [12,  5,  1, 15, 14, 13,  4, 10,  0,  7,  6,  3,  9,  2,  8, 11],
        [13, 11,  7, 14, 12,  1,  3,  9,  5,  0, 15,  4,  8,  6,  2, 10],
        [ 6, 15, 14,  9, 11,  3,  0,  8, 12,  2, 13,  7,  1,  4, 10,  5],
        [10,  2,  8,  4,  7,  6,  1,  5, 15, 11,  9, 14,  3, 12, 13,  0],
      ].freeze
      private_constant :BLAKE2B_SIGMA

      def self.rotr64(x, n)
        ((x >> n) | (x << (64 - n))) & MASK64
      end
      private_class_method :rotr64

      def self.b2b_g(v, a, b, c, d, x, y)
        v[a] = (v[a] + v[b] + x) & MASK64
        v[d] = rotr64(v[d] ^ v[a], 32)
        v[c] = (v[c] + v[d]) & MASK64
        v[b] = rotr64(v[b] ^ v[c], 24)
        v[a] = (v[a] + v[b] + y) & MASK64
        v[d] = rotr64(v[d] ^ v[a], 16)
        v[c] = (v[c] + v[d]) & MASK64
        v[b] = rotr64(v[b] ^ v[c], 63)
      end
      private_class_method :b2b_g

      def self.b2b_compress(h, m, counter, last_block)
        v = h.dup + BLAKE2B_IV.dup
        v[12] ^= counter & MASK64
        v[14] ^= MASK64 if last_block

        # 12 rounds; rows 10 and 11 reuse SIGMA rows 0 and 1.
        12.times do |r|
          s = BLAKE2B_SIGMA[r % 10]
          b2b_g(v, 0, 4,  8, 12, m[s[ 0]], m[s[ 1]])
          b2b_g(v, 1, 5,  9, 13, m[s[ 2]], m[s[ 3]])
          b2b_g(v, 2, 6, 10, 14, m[s[ 4]], m[s[ 5]])
          b2b_g(v, 3, 7, 11, 15, m[s[ 6]], m[s[ 7]])
          b2b_g(v, 0, 5, 10, 15, m[s[ 8]], m[s[ 9]])
          b2b_g(v, 1, 6, 11, 12, m[s[10]], m[s[11]])
          b2b_g(v, 2, 7,  8, 13, m[s[12]], m[s[13]])
          b2b_g(v, 3, 4,  9, 14, m[s[14]], m[s[15]])
        end

        8.times { |i| h[i] ^= v[i] ^ v[i + 8] }
      end
      private_class_method :b2b_compress

      def self.blake2b256(input)
        # Parameter block word 0: outlen=32, keylen=0, fanout=1, maxdepth=1.
        p0 = 0x0000_0000_0101_0020

        h = BLAKE2B_IV.dup
        h[0] ^= p0

        data     = input.b
        data_len = data.bytesize

        if data_len == 0
          b2b_compress(h, [0] * 16, 0, true)
        else
          offset = 0
          loop do
            remaining = data_len - offset
            if remaining <= 128
              padded = data[offset, remaining].ljust(128, "\x00")
              b2b_compress(h, padded.unpack("Q<16"), data_len, true)
              break
            else
              chunk = data[offset, 128]
              b2b_compress(h, chunk.unpack("Q<16"), offset + 128, false)
              offset += 128
            end
          end
        end

        h[0, 4].pack("Q<4")
      end

      def self.rotl64(x, n)
        ((x << n) | (x >> (64 - n))) & MASK64
      end
      private_class_method :rotl64

      def self.sipround(v0, v1, v2, v3)
        v0 = (v0 + v1) & MASK64
        v1 = rotl64(v1, 13) ^ v0
        v0 = rotl64(v0, 32)
        v2 = (v2 + v3) & MASK64
        v3 = rotl64(v3, 16) ^ v2
        v0 = (v0 + v3) & MASK64
        v3 = rotl64(v3, 21) ^ v0
        v2 = (v2 + v1) & MASK64
        v1 = rotl64(v1, 17) ^ v2
        v2 = rotl64(v2, 32)
        [v0, v1, v2, v3]
      end
      private_class_method :sipround

      # SipHash-2-4 as Cuckatoo uses it: the keys are NOT XORed with the standard magic constants.
      def self.siphash(k0, k1, k2, k3, nonce)
        v0 = k0
        v1 = k1
        v2 = k2
        v3 = k3 ^ nonce

        v0, v1, v2, v3 = sipround(v0, v1, v2, v3)
        v0, v1, v2, v3 = sipround(v0, v1, v2, v3)

        v0 ^= nonce
        v2 ^= 0xff

        v0, v1, v2, v3 = sipround(v0, v1, v2, v3)
        v0, v1, v2, v3 = sipround(v0, v1, v2, v3)
        v0, v1, v2, v3 = sipround(v0, v1, v2, v3)
        v0, v1, v2, v3 = sipround(v0, v1, v2, v3)

        (v0 ^ v1) ^ (v2 ^ v3)
      end

      def self.verify_cycle(keys:, edgebits:, cycle:, proofsize: 42)
        n_nodes = 1 << edgebits
        mask    = n_nodes - 1
        k0, k1, k2, k3 = keys
        ps      = proofsize

        return false unless cycle.length == ps

        uvs_size = 2 * ps
        uvs = Array.new(uvs_size, 0)

        cycle.each_with_index do |edge, n|
          return false unless edge.is_a?(Integer)
          return false if edge >= n_nodes
          return false if n > 0 && edge <= cycle[n - 1]
          uvs[2 * n]     = siphash(k0, k1, k2, k3, 2 * edge) & mask
          uvs[2 * n + 1] = siphash(k0, k1, k2, k3, 2 * edge + 1) & mask
        end

        # Walk the cycle: from endpoint i find the one same-parity endpoint j on the
        # same node (>> 1), cross edge j to j ^ 1, and return to 0 in proofsize steps.
        i = 0
        n = 0

        loop do
          j = i
          k = i

          loop do
            k = (k + 2) % uvs_size
            break if k == i
            if (uvs[k] >> 1) == (uvs[i] >> 1)
              return false if j != i
              j = k
            end
          end

          return false if j == i
          return false if uvs[j] == uvs[i]

          i = j ^ 1
          n += 1
          break if i == 0
        end

        n == ps
      end

      # `target` is a 256-bit Integer the sorted cycle's BLAKE2b-256 must stay below; nil accepts any cycle.
      def self.params(edgebits:, proofsize: 42, target: nil)
        { edgebits:, proofsize:, target: }
      end

      # All-nil when unreadable, so {.verify} answers false instead of raising.
      def self.coerce_params(params)
        return [nil, nil, nil] unless params.is_a?(Hash)

        edgebits  = Integer(params[:edgebits]  || params["edgebits"])
        proofsize = Integer(params[:proofsize] || params["proofsize"] || 42)
        target    = params[:target] || params["target"]
        target    = Integer(target) unless target.nil?

        [edgebits, proofsize, target]
      rescue ArgumentError, TypeError
        [nil, nil, nil]
      end
      private_class_method :coerce_params

      def self.verify(salt:, params:, nonce:)
        return false unless nonce.is_a?(Hash)

        header_nonce = nonce[:header_nonce] || nonce["header_nonce"]
        cycle        = nonce[:cycle]        || nonce["cycle"]
        return false if header_nonce.nil? || cycle.nil?

        return false unless cycle.is_a?(Array)

        edgebits, proofsize, target = coerce_params(params)
        return false if edgebits.nil?

        header_nonce = begin
          Integer(header_nonce)
        rescue ArgumentError, TypeError
          return false
        end
        header = salt.b + [header_nonce].pack("V")

        hdr32          = blake2b256(header)
        k0, k1, k2, k3 = hdr32.unpack("Q<4")

        return false unless verify_cycle(
          keys:      [k0, k1, k2, k3],
          edgebits:  edgebits,
          cycle:     cycle,
          proofsize: proofsize
        )

        if target
          cycle_packed = cycle.sort.pack("Q<*")
          cycle_hash   = blake2b256(cycle_packed)
          # The hash is read as a big-endian integer.
          hash_int = cycle_hash.unpack("C*").reduce(0) { |acc, b| (acc << 8) | b }
          return false if hash_int >= target
        end

        true
      end
    end
  end
end
