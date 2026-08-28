# frozen_string_literal: true

require_relative "equihash/version"

module Kiosk
  module Pow
    # Equihash memory-hard proof-of-work backend for Kiosk.
    #
    # Birthday-collision PoW (Biryukov & Khovratovich, 2016).
    # Default parameters: (n=168, k=7) → ~1.3 GiB peak, and ~10s on the
    # reference numpy solver as measured on one M-series laptop core and no
    # other hardware; the GiB is that solver's table, not a floor (n, k)
    # imposes on every implementation -- a memory-optimised solver trades it
    # for time, which is how 200/9's real footprint fell to ~144 MB (see
    # bench/). Equihash is NOT ASIC- or GPU-proof — its role here is a
    # cheap-to-verify metered toll, not a hardware equaliser.
    #
    # == Algorithm
    #
    # The solver finds 2^k nonces whose BLAKE2b-256(seed ‖ nonce) outputs
    # XOR to zero in the first n bits AND form a valid collision tree
    # (Wagner's algorithm).  The verifier recomputes up to 2^k hashes and
    # checks both conditions — ~18 ms for a VALID proof (pure Ruby, 128
    # BLAKE2b at the default params), ~KB of memory.
    #
    # A WRONG proof costs far less: the checks run cheapest-first and the
    # hashing is lazy, so a proof that fails on structure never hashes at all
    # and one that fails on its first sibling pair stops after 2 hashes
    # (~0.3 ms). That gap is deliberate — .verify is reachable
    # unauthenticated on `POST /auth/register` (K-540).
    #
    # == Wire API
    #
    # The proof `nonce` is a Hash:
    #   { indices: [128 u64 integers in Zcash-canonical tree order] }
    # (canonical order, NOT a global sort — see #verify).
    #
    # `verify(salt:, params:, nonce:)` first checks the indices structurally
    # (count, type, range, distinctness, canonical subtree ordering — no
    # hashing at all), then recomputes up to 128 BLAKE2b-256 hashes pair by
    # pair, extracting n bits from each, checking the Wagner collision tree
    # level by level and finally the global XOR = 0.
    #
    # == No difficulty target
    #
    # Difficulty is tuned via (n, k) parameters only — no post-hoc target
    # check.  This avoids bugs from mixing level-collision semantics with
    # an extra threshold constraint.  Providers raise memory by increasing n
    # or decreasing k.
    module Equihash
      # Algorithm identifier used in challenge params.
      #
      # Equihash is the shipped default Kiosk PoW backend — chosen over Argon2id
      # (verify is 64 MiB → unacceptable for gateway) and Cuckatoo29 (4 GiB
      # solver → excessive for mobile clients); see README.md for the full
      # comparison. Defaultness is established by registry wiring, not a
      # constant on this module.
      NAME = "equihash"

      # Default parameters (benchmark-chosen; see .params and bench/).
      DEFAULT_N = 168
      DEFAULT_K = 7

      # Exclusive upper bound on a solution index. The wire type is a u64 and
      # `pack("Q<")` truncates a larger Integer mod 2**64 instead of raising,
      # so the bound has to be stated here or `idx` and `idx + 2**64` would be
      # two distinct indices sharing one hash (K-540 range pre-check).
      MAX_INDEX = 1 << 64

      # Exclusive upper bound on `header_nonce`. Both specs call the field a
      # u32 (`protocol.md` Section 10, `specification.html`, and the
      # `pow.schema.json` description), and `pack("V")` truncates a larger
      # Integer mod 2**32 exactly as `pack("Q<")` truncates mod 2**64 — so
      # without this bound `0`, `2**32` and `-(2**32)` are three spellings of
      # ONE proof and all three verify true against the same indices (K-842,
      # the sibling of K-540's `MAX_INDEX` and K-839's schema bound).
      MAX_HEADER_NONCE = 1 << 32

      # Inclusive bounds on `n`, the number of hash bits a solution must cancel.
      # A leaf is the first `n / 8` bytes of a BLAKE2b-256 digest read as an
      # integer, so below 8 bits there is nothing to read (every leaf is 0 and
      # any distinct indices "solve" the challenge) and above 256 bits there is
      # nothing left to demand (the level shifts exceed the node's width, so
      # every check passes). Neither is reachable from the wire — parameters are
      # re-derived from live config before the backend runs — but a verifier
      # with no answer for its own configuration is how a vacuous accept ships
      # (K-840).
      MIN_N = 8
      MAX_N = 256

      # Absolute path of the reference Python solver, +solve.py+, as shipped
      # INSIDE this gem's package (it is listed in the gemspec's spec.files).
      #
      # PUBLIC API: anything that shells out to the solver — the kiosk-redteam
      # client, a demo script, an assistant runtime — asks this gem for the
      # location instead of hardcoding a checkout-relative path, which resolves
      # only in the monorepo working tree and raises Errno::ENOENT from an
      # installed gem:
      #
      #   Open3.capture2("python3", Kiosk::Pow::Equihash.solver_path, payload)
      #
      # This method only names the file; RUNNING it needs python3 + numpy
      # (see README, "Solver (Python + numpy)").
      #
      # @return [String] absolute path of solve.py inside the installed gem
      def self.solver_path
        File.expand_path("../../../solve.py", __dir__)
      end

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
      # consumer-laptop budget (p95 ~10s on one M-series laptop core, the only
      # hardware the seconds have been measured on; the ~1.3 GiB peak is
      # THIS solver's table, not a floor (n, k) imposes on every
      # implementation). n_div = n/(k+1) = 21
      # drives cost; n must be a multiple of 8 and n_div must not exceed 24. See
      # bench/README.md for the measured grid. Providers tune
      # ("N ∝ cost of serving the verb"): raise n for a heavier toll, raise the
      # policy's proof count for throughput pricing.
      #
      # @param n [Integer] total hash bits (default 168)
      # @param k [Integer] tree depth (default 7); 2^k indices in solution
      # @return [Hash]
      def self.params(n: 168, k: 7)
        { n:, k: }
      end

      # Would a challenge minted at `params` be answerable at all? (K-843)
      #
      # This is the MINT-time half of {verify}'s Step 0. Step 0 gives a
      # degenerate (n, k) an answer — `false` — so a proof solved against it can
      # never verify. That is closed and loud, but it fails at the wrong end:
      # the operator who configured `{n: 0}` learns nothing, and the agent is
      # told "invalid proof of work" for a proof that was correct. A caller that
      # is about to ISSUE a challenge asks this first and refuses to mint one it
      # could never accept.
      #
      # The predicate is EXACTLY Step 0's parameter checks — Step 0 calls it, so
      # the two cannot drift and the accepted set is identical by construction.
      # `{}` is valid: both members default (168/7).
      #
      # Reached generically through
      # `Kiosk::Reputation::Backends.valid_params?("equihash", params)`, which
      # is why it takes one positional Hash rather than keywords.
      #
      # @param params [Hash] as returned by {.params}
      # @return [Boolean] false iff no proof at these parameters could verify
      def self.valid_params?(params)
        n, k = coerce_params(params)
        return false if n.nil?

        # k = 0 is legitimate (no tree; Step 4 is then the only check), k < 0 is
        # not: `1 << k` collapses to 0 and the whole solution disappears.
        return false if k.negative?
        # n is read out of a BLAKE2b-256 digest `n / 8` bytes wide, so below 8
        # there are no bits to read and above 256 there are none left to demand
        # — both make the level checks pass on anything.
        return false unless n >= MIN_N && n <= MAX_N
        # Bits per level. At zero every level check shifts the node clean away
        # and only the root constraint survives, which is not this algorithm.
        # This also bounds k at n - 1, which is what keeps `1 << k` sane.
        (n / (k + 1)).positive?
      end

      # `params` → `[n, k]`, or `[nil, nil]` when it is not a Hash of integers.
      # Split out so {valid_params?} and {verify}'s Step 0 read the pair the
      # same way; neither may raise on caller-supplied junk.
      def self.coerce_params(params)
        return [nil, nil] unless params.is_a?(Hash)

        [Integer(params[:n] || params["n"] || DEFAULT_N),
         Integer(params[:k] || params["k"] || DEFAULT_K)]
      rescue ArgumentError, TypeError
        [nil, nil]
      end
      private_class_method :coerce_params

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

        # ── Step 0: the PARAMETERS themselves (K-840) ────────────────────────
        #
        # `params` reaches here from the challenge object, which the operator's
        # own config minted and `Challenge.verify` re-derived (K-541), so a
        # degenerate (n, k) is a MISCONFIGURATION and not something a caller can
        # choose. That is exactly why it needs an answer rather than an
        # accident: before this block a degenerate k made `.verify` CRASH
        # (`1 << -5` is 0, so 0 indices "matched", the fold loop never ran and
        # Step 4 dereferenced an empty stack) and a degenerate n made it return
        # a vacuous TRUE (`n = 0` → `n_bytes = 0` → every leaf is the integer 0,
        # so ANY 2^k distinct indices "solve" it). A verifier must never invent
        # a proof that was not supplied; when it cannot evaluate the question it
        # answers `false`.
        #
        # The bounds are the ones the arithmetic below actually needs, and no
        # more — every parameter pair this gem, the demos and the specs use
        # (168/7, 96/5, 200/9, 32/3, 24/2, 8/1, 8/2, 8/3) satisfies them, so the
        # ACCEPTED SET IS UNCHANGED. They live in {valid_params?} so the gate
        # that MINTS a challenge can ask the same question before issuing one
        # (K-843) and the two can never disagree.
        return false unless valid_params?(params)

        n, k  = coerce_params(params)
        n_div = n / (k + 1)  # bits per level: 168/8 = 21

        expected_len = 1 << k  # 2^k
        return false unless indices.length == expected_len

        # Indices must be distinct non-negative integers below 2**64 — the wire
        # type is a u64 (see the module docstring). Their ORDER is NOT a global
        # sort — a genuine Wagner solution's canonical order is not ascending;
        # ordering is enforced structurally in Step 2 (Zcash subtree rule).
        #
        # Reject any element that is not a plain Integer (nil, String, Float,
        # …) rather than coercing — a malformed index means a malformed proof,
        # which must return false, never raise.
        #
        # The upper bound is not decoration: `pack("Q<")` silently truncates a
        # bignum mod 2**64, so without it `idx` and `idx + 2**64` hash the same
        # and one solution could be restated as many (K-540 range pre-check).
        return false unless indices.all? { |idx| idx.is_a?(Integer) && idx >= 0 && idx < MAX_INDEX }
        return false unless indices.uniq.length == expected_len

        n_bytes = n / 8       # 21 bytes for 168 bits

        # ── Step 2: canonical subtree ORDERING — the cheapest constraint ──────
        #
        # Zcash "algorithm binding": at every tree node the left half's first
        # index precedes the right half's. It rules out trivial reorderings and
        # pins one canonical form per solution — and it reads ONLY `indices`
        # (2^k - 1 integer comparisons, no hashing), so it is hoisted ABOVE
        # every BLAKE2b. `verify` is reachable UNAUTHENTICATED on
        # `POST /auth/register`, where a check costing microseconds must never
        # sit behind one costing milliseconds (K-540).
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

        # Build the seed: salt bytes ‖ header_nonce as LE u32 (future-proofing).
        # header_nonce defaults to 0 for now; extensibility point.
        #
        # header_nonce is client-supplied. A non-numeric/non-coercible value
        # means a malformed proof, which must return false, never raise —
        # Integer() throws ArgumentError/TypeError on "abc", [1], {}.
        #
        # The RANGE check is the same argument {MAX_INDEX} makes one screen up:
        # `pack("V")` truncates mod 2**32 rather than raising, so without it
        # `0`, `2**32` and `-(2**32)` seed identically and one proof has
        # infinitely many spellings on the wire (K-842). `pow.schema.json`
        # states the same bound, and the two must move together — bounding
        # only the schema would make it refuse what this verifier accepts.
        hn = nonce[:header_nonce] || nonce["header_nonce"] || 0
        hn = begin
          Integer(hn)
        rescue ArgumentError, TypeError
          return false
        end
        return false unless hn >= 0 && hn < MAX_HEADER_NONCE

        seed = salt.b + [hn].pack("V")

        # ── Step 3: hash leaf by leaf, folding the Wagner tree as we go ───────
        #
        # All 2^k leaf hashes used to be computed up front and only then
        # checked, so a proof that was wrong in its very first sibling pair
        # still cost the whole loop — measured 18.7 ms at n=168 k=7,
        # INDISTINGUISHABLE from a valid proof, which is what made an
        # unauthenticated register a CPU lever (K-540).
        #
        # Instead, fold the tree left-to-right like a binary counter: each new
        # leaf hash is merged with the completed node to its left, and every
        # merge is CHECKED THE MOMENT its inputs exist. A node at height h
        # covers 2^h leaves and its XOR must cancel the top h*n_div bits —
        # exactly the per-level rule, evaluated depth-first instead of
        # level-by-level. So the set of accepted proofs is unchanged; only the
        # moment of rejection moves.
        #
        # That moment is the whole point. Verification now stops at the FIRST
        # node that does not cancel, so the hashes a wrong proof can buy are
        # bounded by how much of a REAL solution it carries: rubbish dies after
        # 2 hashes, and to make the verifier hash all 2^k leaves an attacker
        # must supply an almost-complete Wagner solution — against a salt that
        # is fresh per challenge. Checking level 0 for every pair first would
        # only have cost them 2^(k-1) cheap collisions.
        stack = []  # completed subtrees, left to right: [height, xor]
        i = 0
        while i < expected_len
          node   = leaf_hash(seed, indices[i], n_bytes)
          height = 0

          # Merge with equal-height left neighbours, checking each new node.
          while !stack.empty? && stack.last[0] == height
            node   ^= stack.pop[1]
            height += 1
            return false unless (node >> (n - (height * n_div))).zero?
          end

          stack << [height, node]
          i += 1
        end

        # ── Step 4: the root must cancel ALL n bits ──────────────────────────
        #
        # The merges above cover the top k*n_div bits; n itself may be wider
        # (n_div is an integer division), so the full-width XOR is still its
        # own check. At k=0 there is no tree and this is the only one.
        stack.last[1].zero?
      end

      # One leaf: BLAKE2b-256(seed ‖ LE64(index)), first `n_bytes` bytes read as
      # a big-endian integer (byte[0] most significant → "first X bits").
      # Extracted so {.verify} can hash one leaf at a time.
      def self.leaf_hash(seed, index, n_bytes)
        blake2b256(seed + [index].pack("Q<"))
          .byteslice(0, n_bytes).unpack("C*").reduce(0) { |acc, b| (acc << 8) | b }
      end
      private_class_method :leaf_hash
    end
  end
end
