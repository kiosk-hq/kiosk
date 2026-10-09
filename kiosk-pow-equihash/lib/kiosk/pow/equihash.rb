# frozen_string_literal: true

require_relative "equihash/version"

module Kiosk
  module Pow
    # Equihash proof-of-work verifier (Biryukov & Khovratovich, 2016); default n=168, k=7.
    # The solver finds 2^k nonces whose BLAKE2b-256(seed ‖ nonce) outputs
    # XOR to zero in the first n bits and form a valid Wagner collision tree.
    module Equihash
      NAME = "equihash"

      DEFAULT_N = 168
      DEFAULT_K = 7

      # Upper bounds: `pack` truncates a larger Integer instead of raising, which would make one proof many.
      MAX_INDEX = 1 << 64
      MAX_HEADER_NONCE = 1 << 32

      # A leaf is `n / 8` bytes of a 256-bit digest: below 8 or above 256 bits every check passes.
      MIN_N = 8
      MAX_N = 256

      # Absolute path of the bundled solve.py; running it needs python3 + numpy.
      def self.solver_path
        File.expand_path("../../../solve.py", __dir__)
      end

      # BLAKE2b-256, a copy of kiosk-pow-cuckoo's so this gem has no dependencies.
      MASK64 = (1 << 64) - 1
      private_constant :MASK64

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

      def self.rotr64(x, n) = ((x >> n) | (x << (64 - n))) & MASK64
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
        p0 = 0x0000_0000_0101_0020  # outlen=32, keylen=0, fanout=1, depth=1
        h  = BLAKE2B_IV.dup
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

      # n must be a multiple of 8 and n / (k + 1) at most 24; bench/ holds the measured grid.
      def self.params(n: 168, k: 7)
        { n:, k: }
      end

      # Mint-time check: false iff no proof at these parameters could verify.
      def self.valid_params?(params)
        n, k = coerce_params(params)
        return false if n.nil?

        return false if k.negative?
        return false unless n >= MIN_N && n <= MAX_N
        (n / (k + 1)).positive?
      end

      def self.coerce_params(params)
        return [nil, nil] unless params.is_a?(Hash)

        [Integer(params[:n] || params["n"] || DEFAULT_N),
         Integer(params[:k] || params["k"] || DEFAULT_K)]
      rescue ArgumentError, TypeError
        [nil, nil]
      end
      private_class_method :coerce_params

      # Checks run cheapest-first: this is reachable unauthenticated on `POST /auth/register`.
      def self.verify(salt:, params:, nonce:)
        return false unless nonce.is_a?(Hash)

        indices = nonce[:indices] || nonce["indices"]
        return false if indices.nil? || !indices.is_a?(Array)

        return false unless valid_params?(params)

        n, k  = coerce_params(params)
        n_div = n / (k + 1)

        expected_len = 1 << k
        return false unless indices.length == expected_len

        return false unless indices.all? { |idx| idx.is_a?(Integer) && idx >= 0 && idx < MAX_INDEX }
        return false unless indices.uniq.length == expected_len

        n_bytes = n / 8

        # Zcash canonical order: at every tree node the left half's first index precedes the right half's.
        level = 0
        while level < k
          group_size = 1 << (level + 1)
          half       = group_size >> 1
          base       = 0
          while base < expected_len
            return false unless indices[base] < indices[base + half]

            base += group_size
          end
          level += 1
        end

        hn = nonce[:header_nonce] || nonce["header_nonce"] || 0
        hn = begin
          Integer(hn)
        rescue ArgumentError, TypeError
          return false
        end
        return false unless hn >= 0 && hn < MAX_HEADER_NONCE

        seed = salt.b + [hn].pack("V")

        # Fold the tree left to right, checking each node as soon as it exists, so a wrong proof stops early.
        stack = []  # completed subtrees, left to right: [height, xor]
        i = 0
        while i < expected_len
          node   = leaf_hash(seed, indices[i], n_bytes)
          height = 0

          while !stack.empty? && stack.last[0] == height
            node   ^= stack.pop[1]
            height += 1
            return false unless (node >> (n - (height * n_div))).zero?
          end

          stack << [height, node]
          i += 1
        end

        # The levels cover k * n_div bits; the root must cancel all n.
        stack.last[1].zero?
      end

      # BLAKE2b-256(seed ‖ LE64(index)), first `n_bytes` read as a big-endian integer.
      def self.leaf_hash(seed, index, n_bytes)
        blake2b256(seed + [index].pack("Q<"))
          .byteslice(0, n_bytes).unpack("C*").reduce(0) { |acc, b| (acc << 8) | b }
      end
      private_class_method :leaf_hash
    end
  end
end
