# frozen_string_literal: true

require "kiosk/pow/cuckoo/version"

module Kiosk
  module Pow
    # Cuckatoo-Cycle proof-of-work backend for Kiosk.
    #
    # Clean-room implementation from the Cuckatoo algorithm spec (Tromp's
    # doc/spec and doc/mathspec).  Only the VERIFIER is implemented here —
    # the cheap, asymmetric, security-critical side.  The solver is a
    # separate component (see T2 / T3 of the R2 plan).
    #
    # == Primitives (both clean-room, permissive):
    #
    # BLAKE2b-256 — pure Ruby from the public-domain BLAKE2 spec.  No
    #   external dependency; no code from Tromp's repo.
    #
    # SipHash-2-4 (Cuckatoo non-standard init) — pure Ruby from the
    #   public-domain SipHash spec with one deviation: keys are used directly
    #   as v0..v3 WITHOUT XOR-ing the 0x736f6d65... magic constants.
    #
    # == Wire API
    #
    # The composite proof `nonce` is a Hash:
    #   { header_nonce: <u32>, cycle: [42 strictly-ascending edge indices] }
    # (String or Symbol keys are both accepted.)
    #
    # `verify(salt:, params:, nonce:)` builds:
    #   header = salt_bytes ‖ LE32(header_nonce)
    # derives the four siphash keys via blake2b-256(header), then runs the
    # Cuckatoo cycle verifier and an optional difficulty-target check.
    #
    # == Difficulty target
    #
    # When `params[:target]` is set (Integer in [0, 2^256)), the verifier
    # additionally asserts:
    #   blake2b-256( sorted_cycle_edges_packed_as_LE_u64 ) < target
    # where the 32-byte hash is treated as a big-endian 256-bit integer.
    # `nil` target (the default) accepts any valid cycle.
    module Cuckoo
      # Algorithm identifier used in challenge params.
      NAME = "cuckatoo"

      # 64-bit mask for all arithmetic.
      MASK64 = (1 << 64) - 1
      private_constant :MASK64

      # -----------------------------------------------------------------------
      # BLAKE2b-256 — pure Ruby, clean-room from the public-domain BLAKE2 spec.
      # Covers sequential mode (fanout=1, depth=1), no key, no salt/personalization.
      # Output: 32 bytes.
      # Reference: https://www.blake2.net/blake2.pdf (public domain)
      # -----------------------------------------------------------------------

      # BLAKE2b initialization values (identical to the first 8 SHA-512 IVs).
      BLAKE2B_IV = [
        0x6a09e667f3bcc908, 0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
        0x510e527fade682d1, 0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
      ].freeze
      private_constant :BLAKE2B_IV

      # Message schedule permutations for 10 base rounds (cycled to 12).
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

      # Right-rotate a 64-bit integer by n positions.
      def self.rotr64(x, n)
        ((x >> n) | (x << (64 - n))) & MASK64
      end
      private_class_method :rotr64

      # BLAKE2b G mixing function; modifies v in place.
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

      # BLAKE2b compression function.
      # Modifies h (8-element u64 array) in place.
      # m is a 16-element u64 message block.
      # counter is the total bytes processed so far (fits in 64 bits for our inputs).
      # last_block triggers the finalization flag.
      def self.b2b_compress(h, m, counter, last_block)
        # Working vector: v[0..7] = current state h, v[8..15] = IV constants.
        v = h.dup + BLAKE2B_IV.dup
        v[12] ^= counter & MASK64
        # v[13] ^= upper 64 bits of counter — always 0 for inputs < 2^64 bytes.
        v[14] ^= MASK64 if last_block  # invert all bits of v[14] (finalize flag)

        # 12 rounds of mixing (SIGMA is 10 rows; rows 10 and 11 reuse rows 0 and 1).
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

        # Fold the working vector back into the state.
        8.times { |i| h[i] ^= v[i] ^ v[i + 8] }
      end
      private_class_method :b2b_compress

      # Compute BLAKE2b-256 (32-byte output, no key) of +input+ (raw bytes String).
      # Implements sequential hashing mode: fanout=1, depth=1, all other params=0.
      #
      # Public so specs can test it directly against Python hashlib.blake2b vectors.
      def self.blake2b256(input)
        # Parameter block word 0 (LE u64):
        #   byte 0 = outlen=32 (0x20), byte 1 = keylen=0,
        #   byte 2 = fanout=1,  byte 3 = maxdepth=1
        #   → 0x0000_0000_0101_0020
        p0 = 0x0000_0000_0101_0020

        h = BLAKE2B_IV.dup
        h[0] ^= p0

        data     = input.b
        data_len = data.bytesize

        if data_len == 0
          # Empty input: compress one zero block with counter=0 and final=true.
          b2b_compress(h, [0] * 16, 0, true)
        else
          offset = 0
          loop do
            remaining = data_len - offset
            if remaining <= 128
              # Final (possibly partial) block — pad to 128 bytes with zeros.
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

        # First 4 u64 words packed as little-endian = 32 bytes.
        h[0, 4].pack("Q<4")
      end

      # -----------------------------------------------------------------------
      # SipHash-2-4 — Cuckatoo non-standard initialization.
      #
      # Standard SipHash-2-4 XORs k0..k3 with the "magic constants"
      # (0x736f6d65..., 0x646f7261..., 0x6c796765..., 0x74656462...).
      # Cuckatoo deliberately omits that step: keys feed directly into v0..v3.
      #
      # Reference: public-domain SipHash spec by Jean-Philippe Aumasson and
      # Daniel J. Bernstein (https://131002.net/siphash/siphash.pdf).
      # Non-standard init documented in Tromp's doc/spec for Cuckoo Cycle.
      # -----------------------------------------------------------------------

      # Left-rotate a 64-bit integer by n positions.
      def self.rotl64(x, n)
        ((x << n) | (x >> (64 - n))) & MASK64
      end
      private_class_method :rotl64

      # One SipRound (standard left-rotation schedule: 13, 16, 17, 21, 32).
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

      # Cuckatoo SipHash-2-4 with non-standard init.
      #
      # @param k0..k3 [Integer] 64-bit key words (from blake2b-256 of header)
      # @param nonce  [Integer] 64-bit input value (edge endpoint index)
      # @return      [Integer] 64-bit hash output
      def self.siphash(k0, k1, k2, k3, nonce)
        v0 = k0
        v1 = k1
        v2 = k2
        v3 = k3 ^ nonce

        # 2 compression rounds (c=2)
        v0, v1, v2, v3 = sipround(v0, v1, v2, v3)
        v0, v1, v2, v3 = sipround(v0, v1, v2, v3)

        v0 ^= nonce
        v2 ^= 0xff

        # 4 finalization rounds (d=4)
        v0, v1, v2, v3 = sipround(v0, v1, v2, v3)
        v0, v1, v2, v3 = sipround(v0, v1, v2, v3)
        v0, v1, v2, v3 = sipround(v0, v1, v2, v3)
        v0, v1, v2, v3 = sipround(v0, v1, v2, v3)

        (v0 ^ v1) ^ (v2 ^ v3)
      end

      # -----------------------------------------------------------------------
      # Cuckatoo Cycle verifier
      # -----------------------------------------------------------------------

      # Verify a Cuckatoo proof cycle.
      #
      # @param keys     [Array<Integer>] [k0, k1, k2, k3] — four u64 siphash keys
      # @param edgebits [Integer]        log2 of the graph size (e.g. 29)
      # @param cycle    [Array<Integer>] strictly-ascending edge indices (length = proofsize)
      # @param proofsize [Integer]       cycle length (default 42)
      # @return [Boolean]
      def self.verify_cycle(keys:, edgebits:, cycle:, proofsize: 42)
        n_nodes = 1 << edgebits
        mask    = n_nodes - 1
        k0, k1, k2, k3 = keys
        ps      = proofsize

        # Proof must have exactly proofsize edges.
        return false unless cycle.length == ps

        uvs_size = 2 * ps
        uvs = Array.new(uvs_size, 0)

        # Compute U/V endpoints; verify strictly-ascending and in-range.
        cycle.each_with_index do |edge, n|
          return false if edge >= n_nodes
          return false if n > 0 && edge <= cycle[n - 1]   # strict ascending (also deduplicates)
          uvs[2 * n]     = siphash(k0, k1, k2, k3, 2 * edge) & mask
          uvs[2 * n + 1] = siphash(k0, k1, k2, k3, 2 * edge + 1) & mask
        end

        # Walk the single cycle on node-PAIRS (via >> 1).
        #
        # At each step i, we are at a U-side (even i) or V-side (odd i) node.
        # We scan for the unique other endpoint j (same parity, same node-pair
        # value when both right-shifted by 1) and follow edge j to its partner
        # (j ^ 1).  The walk must return to i=0 after exactly proofsize steps.
        i = 0
        n = 0

        loop do
          j = i
          k = i

          # Scan all same-parity indices (step by 2) for a partner.
          loop do
            k = (k + 2) % uvs_size
            break if k == i
            if (uvs[k] >> 1) == (uvs[i] >> 1)
              return false if j != i    # BRANCH: more than one partner found
              j = k
            end
          end

          return false if j == i            # DEAD_END: no partner found
          return false if uvs[j] == uvs[i] # DEAD_END: partner is same exact node (degenerate)

          i = j ^ 1   # cross the edge to the other endpoint
          n += 1
          break if i == 0   # returned to start
        end

        n == ps   # must complete exactly proofsize steps
      end

      # -----------------------------------------------------------------------
      # Public API (backend contract)
      # -----------------------------------------------------------------------

      # Build algorithm-specific challenge params.
      #
      # @param edgebits  [Integer] log2 of graph size (required)
      # @param proofsize [Integer] cycle length (default 42)
      # @param target    [Integer, nil] 256-bit difficulty target as Integer,
      #                                or nil to accept any valid cycle
      # @return [Hash]
      def self.params(edgebits:, proofsize: 42, target: nil)
        { edgebits:, proofsize:, target: }
      end

      # Verify a Cuckatoo proof-of-work.
      #
      # @param salt   [String] raw bytes (the provider's per-challenge salt)
      # @param params [Hash]   as returned by {.params}
      # @param nonce  [Hash]   { header_nonce: Integer, cycle: Array<Integer> }
      #                        (String or Symbol keys are both accepted)
      # @return [Boolean]
      def self.verify(salt:, params:, nonce:)
        return false unless nonce.is_a?(Hash)

        header_nonce = nonce[:header_nonce] || nonce["header_nonce"]
        cycle        = nonce[:cycle]        || nonce["cycle"]
        return false if header_nonce.nil? || cycle.nil?

        edgebits  = Integer(params[:edgebits]  || params["edgebits"])
        proofsize = Integer(params[:proofsize] || params["proofsize"] || 42)
        target    = params[:target] || params["target"]

        # Build the 80-byte header: salt bytes ‖ header_nonce as LE u32.
        header = salt.b + [Integer(header_nonce)].pack("V")

        # Derive SipHash keys from the header.
        hdr32          = blake2b256(header)
        k0, k1, k2, k3 = hdr32.unpack("Q<4")

        # Run the Cuckatoo cycle verifier.
        return false unless verify_cycle(
          keys:      [k0, k1, k2, k3],
          edgebits:  edgebits,
          cycle:     cycle,
          proofsize: proofsize
        )

        # Optional difficulty-target check:
        #   blake2b-256( sorted cycle edges as LE u64 ) < target
        if target
          cycle_packed = cycle.sort.pack("Q<*")
          cycle_hash   = blake2b256(cycle_packed)
          # Interpret both values as big-endian 256-bit integers.
          hash_int   = cycle_hash.unpack("C*").reduce(0) { |acc, b| (acc << 8) | b }
          target_int = target.is_a?(Integer) ? target : target.unpack("C*").reduce(0) { |acc, b| (acc << 8) | b }
          return false if hash_int >= target_int
        end

        true
      end
    end
  end
end
