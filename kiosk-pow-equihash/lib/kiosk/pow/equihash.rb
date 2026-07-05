# frozen_string_literal: true

require_relative "equihash/version"

module Kiosk
  module Pow
    # Equihash memory-hard proof-of-work backend for Kiosk.
    #
    # Birthday-collision PoW (Biryukov & Khovratovich, 2016).
    # Default parameters: (n=192, k=7) → ~1 GiB solver memory.
    #
    # == Algorithm
    #
    # The solver finds 2^k nonces whose BLAKE2b-256(seed ‖ nonce) outputs
    # XOR to zero in the first n bits AND form a valid collision tree
    # (Wagner's algorithm).  The verifier recomputes 2^k hashes and checks
    # both conditions — microseconds, ~KB of memory.
    #
    # == Wire API
    #
    # The proof `nonce` is a Hash:
    #   { indices: [128 strictly-ascending u64 integers] }
    #
    # `verify(salt:, params:, nonce:)` recomputes 128 BLAKE2b-256 hashes,
    # extracts n bits from each, checks the collision tree, and verifies
    # the global XOR = 0.
    #
    # == No difficulty target
    #
    # Difficulty is tuned via (n, k) parameters only — no post-hoc target
    # check.  This avoids bugs from mixing level-collision semantics with
    # an extra threshold constraint.  Providers raise memory by increasing n
    # or decreasing k.
    module Equihash
      # Algorithm identifier used in challenge params.
      NAME = "equihash"

      # Equihash is the default Kiosk PoW backend.
      # Chosen over Argon2id (verify is 64 MiB → unacceptable for gateway)
      # and Cuckatoo29 (4 GiB solver → excessive for mobile clients).
      # See README.md for the full comparison.
      DEFAULT = true

      # Default production parameters: ~1 GiB solver memory, µs verify.
      DEFAULT_N = 192
      DEFAULT_K = 7

      # ───────────────────────────────────────────────────────────────────
      # BLAKE2b-256 — pure Ruby, clean-room from the public-domain BLAKE2 spec.
      # Identical to the implementation in kiosk-pow-cuckoo; copied here
      # so this gem has zero dependencies.
      # Reference: https://www.blake2.net/blake2.pdf (public domain)
      # ───────────────────────────────────────────────────────────────────

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

      # Compute BLAKE2b-256 (32-byte output, no key) of +input+ (raw bytes).
      # Public so specs can test it directly against Python hashlib.blake2b vectors.
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

        h[0, 4].pack("Q<4")  # first 4 u64 words as LE = 32 bytes
      end

      # ───────────────────────────────────────────────────────────────────
      # Equihash verification
      # ───────────────────────────────────────────────────────────────────

      # Build algorithm-specific challenge params.
      #
      # @param n [Integer] total hash bits (default 192)
      # @param k [Integer] tree depth (default 7); 2^k indices in solution
      # @return [Hash]
      def self.params(n: 192, k: 7)
        { n:, k: }
      end

      # Verify an Equihash proof-of-work.
      #
      # @param salt   [String] raw bytes (the provider's per-challenge salt)
      # @param params [Hash]   as returned by {.params}
      # @param nonce  [Hash]   { indices: Array<Integer> }
      #                        (Symbol or String keys are both accepted)
      # @return [Boolean]
      def self.verify(salt:, params:, nonce:)
        return false unless nonce.is_a?(Hash)

        indices = nonce[:indices] || nonce["indices"]
        return false if indices.nil? || !indices.is_a?(Array)

        n = Integer(params[:n]  || params["n"]  || 192)
        k = Integer(params[:k]  || params["k"]  || 7)

        expected_len = 1 << k  # 2^k
        return false unless indices.length == expected_len

        # Strictly ascending, no duplicates.
        prev = -1
        indices.each do |idx|
          return false if idx.is_a?(Float)  # reject floats outright
          i = Integer(idx)
          return false unless i > prev
          prev = i
        end

        n_div = n / (k + 1)  # bits per level: 192/8 = 24
        n_bytes = n / 8       # 24 bytes for 192 bits

        # Build the seed: salt bytes ‖ header_nonce as LE u32 (future-proofing).
        # header_nonce defaults to 0 for now; extensibility point.
        hn = nonce[:header_nonce] || nonce["header_nonce"] || 0
        seed = salt.b + [Integer(hn)].pack("V")

        # Step 1: Compute all 2^k hashes and extract n bits as integers.
        hash_vals = indices.map do |idx|
          h = blake2b256(seed + [Integer(idx)].pack("Q<"))
          # Take first n_bytes (24), convert to big-endian integer.
          # byte[0] is most significant → matches "first X bits" semantics.
          h.byteslice(0, n_bytes).unpack("C*").reduce(0) { |acc, b| (acc << 8) | b }
        end

        # Step 2: Global XOR must be zero on all n bits.
        xor_all = hash_vals.reduce(0) { |acc, v| acc ^ v }
        return false unless xor_all == 0

        # Step 3: Verify the Wagner collision tree.
        # Level j (0-indexed): groups of size 2^(j+1) must collide on
        # (j+1) * n_div most-significant bits.
        (0...k).each do |level|
          group_size = 1 << (level + 1)                     # 2, 4, 8, ..., 128
          num_groups = expected_len / group_size            # 64, 32, 16, ..., 1
          prefix_bits = (level + 1) * n_div                 # 24, 48, 72, ..., 168
          prefix_shift = n - prefix_bits                    # 168, 144, 120, ..., 24

          num_groups.times do |g|
            base_prefix = hash_vals[g * group_size] >> prefix_shift
            (1...group_size).each do |i|
              return false unless (hash_vals[g * group_size + i] >> prefix_shift) == base_prefix
            end
          end
        end

        true
      end
    end
  end
end
