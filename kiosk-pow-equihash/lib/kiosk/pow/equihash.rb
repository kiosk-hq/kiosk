# frozen_string_literal: true

require_relative "equihash/version"

module Kiosk
  module Pow
    # Equihash memory-hard proof-of-work backend for Kiosk.
    #
    # Birthday-collision PoW (Biryukov & Khovratovich, 2016).
    # Default parameters: (n=168, k=7) → ~1.3 GiB / ~10s reference solve
    # (see bench/). Equihash is NOT ASIC- or GPU-proof — its role here is a
    # cheap-to-verify metered toll, not a hardware equaliser (ADR-0007).
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
    #   { indices: [128 u64 integers in Zcash-canonical tree order] }
    # (canonical order, NOT a global sort — see #verify).
    #
    # `verify(salt:, params:, nonce:)` recomputes 128 BLAKE2b-256 hashes,
    # extracts n bits from each, checks the Wagner collision tree (per-level
    # XOR cancellation + canonical subtree ordering), and verifies the global
    # XOR = 0.
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

      # Default parameters (benchmark-chosen; see .params and bench/).
      DEFAULT_N = 168
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
      # Default (n=168, k=7): chosen by the parameter sweep in bench/ — the
      # largest params whose reference numpy solve stays under a ~30s / 1-2 GiB
      # consumer-laptop budget (p95 ~10s, ~1.3 GiB peak). n_div = n/(k+1) = 21
      # drives cost; n must be a multiple of 8 and n_div must not exceed 24. See
      # bench/README.md for the measured grid. Providers tune per ADR-0007
      # ("N ∝ cost of serving the verb"): raise n for a heavier toll, raise the
      # policy's proof count for throughput pricing.
      #
      # @param n [Integer] total hash bits (default 168)
      # @param k [Integer] tree depth (default 7); 2^k indices in solution
      # @return [Hash]
      def self.params(n: 168, k: 7)
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

        n = Integer(params[:n]  || params["n"]  || DEFAULT_N)
        k = Integer(params[:k]  || params["k"]  || DEFAULT_K)

        expected_len = 1 << k  # 2^k
        return false unless indices.length == expected_len

        # Indices must be distinct non-negative integers. Their ORDER is NOT a
        # global sort — a genuine Wagner solution's canonical order is not
        # ascending. Ordering is enforced structurally below (Zcash subtree
        # rule: at each tree node the left half's first index precedes the
        # right half's), which also rules out trivial reorderings.
        return false if indices.any? { |idx| idx.is_a?(Float) || Integer(idx) < 0 }
        return false unless indices.uniq.length == expected_len

        n_div = n / (k + 1)  # bits per level: 168/8 = 21
        n_bytes = n / 8       # 21 bytes for 168 bits

        # Build the seed: salt bytes ‖ header_nonce as LE u32 (future-proofing).
        # header_nonce defaults to 0 for now; extensibility point.
        hn = nonce[:header_nonce] || nonce["header_nonce"] || 0
        seed = salt.b + [Integer(hn)].pack("V")

        # Step 1: Compute all 2^k hashes and extract n bits as integers.
        hash_vals = indices.map do |idx|
          h = blake2b256(seed + [Integer(idx)].pack("Q<"))
          # Take first n_bytes (21 for n=168), convert to big-endian integer.
          # byte[0] is most significant → matches "first X bits" semantics.
          h.byteslice(0, n_bytes).unpack("C*").reduce(0) { |acc, b| (acc << 8) | b }
        end

        # Step 2: Global XOR must be zero on all n bits.
        xor_all = hash_vals.reduce(0) { |acc, v| acc ^ v }
        return false unless xor_all == 0

        # Step 3: Verify the Wagner collision tree (Zcash-canonical).
        #
        # At level j (0-indexed) the solution splits into groups of 2^(j+1)
        # leaves. For each group:
        #
        #   (a) the XOR of the group's leaf hashes CANCELS the top (j+1)*n_div
        #       bits — this is how Wagner works (siblings' XOR zeros the block).
        #       The leaves do NOT share a common prefix; only their XOR does.
        #   (b) canonical ordering: the left half's first index precedes the
        #       right half's (Zcash "algorithm binding" — rules out trivial
        #       reorderings and pins one canonical form per solution).
        #
        # Applied at every level, (a) is equivalent to the classic
        # generalized-birthday collision tree; combined with Step 2 (the full
        # n-bit XOR) it fully constrains the solution.
        (0...k).each do |level|
          group_size   = 1 << (level + 1)                   # 2, 4, 8, ..., 2^k
          num_groups   = expected_len / group_size
          prefix_bits  = (level + 1) * n_div                # 21, 42, ..., k*21
          prefix_shift = n - prefix_bits
          half         = group_size / 2

          num_groups.times do |g|
            base = g * group_size

            group_xor = 0
            group_size.times { |i| group_xor ^= hash_vals[base + i] }
            return false unless (group_xor >> prefix_shift).zero?

            return false unless indices[base] < indices[base + half]
          end
        end

        true
      end
    end
  end
end
