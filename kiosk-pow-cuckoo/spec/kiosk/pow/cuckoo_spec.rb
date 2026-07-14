# frozen_string_literal: true

require "spec_helper"
require "base64"

RSpec.describe Kiosk::Pow::Cuckoo do
  # ---------------------------------------------------------------------------
  # Grin Cuckatoo29 Known-Answer Vector (C29, nonce=20)
  #
  # Keying: blake2b-256( ("\x00"*76) + [20].pack("V") ) → keys as LE u64.
  # This reproduces Grin's set_header_nonce(header=80-zero-bytes, nonce=20).
  #
  # The 42-cycle below is the unique valid cycle for this header+nonce combo,
  # taken directly from Grin's CI test suite (cuckatoo29 constant).
  #
  # Python cross-reference:
  #   import hashlib
  #   hashlib.blake2b(b"\x00"*76 + b"\x14\x00\x00\x00", digest_size=32).hexdigest()
  #   => "770129fe760558276ee7f431209beaf98f8607868c3063160e0d18fab03988b8"
  # ---------------------------------------------------------------------------

  KAT_EDGEBITS = 29
  KAT_SALT     = ("\x00" * 76).freeze
  KAT_NONCE    = 20

  KAT_CYCLE = [
    0x48a9e2,    0x9cf043,    0x155ca30,   0x18f4783,
    0x248f86c,   0x2629a64,   0x5bad752,   0x72e3569,
    0x93db760,   0x97d3b37,   0x9e05670,   0xa315d5a,
    0xa3571a1,   0xa48db46,   0xa7796b6,   0xac43611,
    0xb64912f,   0xbb6c71e,   0xbcc8be1,   0xc38a43a,
    0xd4faa99,   0xe018a66,   0xe37e49c,   0xfa975fa,
    0x11786035,  0x1243b60a,  0x12892da0,  0x141b5453,
    0x1483c3a0,  0x1505525e,  0x1607352c,  0x16181fe3,
    0x17e3a1da,  0x180b651e,  0x1899d678,  0x1931b0bb,
    0x19606448,  0x1b041655,  0x1b2c20ad,  0x1bd7a83c,
    0x1c05d5b0,  0x1c0b9caa,
  ].freeze

  # Expected blake2b-256 of the KAT header (Python-cross-referenced).
  KAT_BLAKE2B_HEX = "770129fe760558276ee7f431209beaf98f8607868c3063160e0d18fab03988b8"

  # Derive the raw keys used in the lower-level tests.
  KAT_KEYS = begin
    hdr = KAT_SALT + [KAT_NONCE].pack("V")
    described_class.blake2b256(hdr).unpack("Q<4")
  end

  # ---------------------------------------------------------------------------
  # NAME
  # ---------------------------------------------------------------------------

  describe "NAME" do
    it "is 'cuckatoo'" do
      expect(described_class::NAME).to eq("cuckatoo")
    end
  end

  # ---------------------------------------------------------------------------
  # .params
  # ---------------------------------------------------------------------------

  describe ".params" do
    it "returns a hash with edgebits, proofsize, and target" do
      p = described_class.params(edgebits: 29)
      expect(p).to include(edgebits: 29, proofsize: 42, target: nil)
    end

    it "accepts custom proofsize and target" do
      p = described_class.params(edgebits: 19, proofsize: 42, target: 1234)
      expect(p).to eq({ edgebits: 19, proofsize: 42, target: 1234 })
    end
  end

  # ---------------------------------------------------------------------------
  # .blake2b256 — known-answer vectors
  #
  # Cross-referenced against Python:
  #   hashlib.blake2b(b"", digest_size=32).hexdigest()
  #   => "0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8"
  #   hashlib.blake2b(b"\x00"*76 + b"\x14\x00\x00\x00", digest_size=32).hexdigest()
  #   => "770129fe760558276ee7f431209beaf98f8607868c3063160e0d18fab03988b8"
  # ---------------------------------------------------------------------------

  describe ".blake2b256" do
    it "matches Python hashlib.blake2b for empty input" do
      result = described_class.blake2b256("".b)
      expect(result.unpack1("H*")).to eq(
        "0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8"
      )
    end

    it "matches Python hashlib.blake2b for the KAT header (76 zeros + LE32(20))" do
      header = KAT_SALT + [KAT_NONCE].pack("V")
      result = described_class.blake2b256(header)
      expect(result.unpack1("H*")).to eq(KAT_BLAKE2B_HEX)
    end

    it "returns 32 raw bytes" do
      expect(described_class.blake2b256("hello").bytesize).to eq(32)
    end

    it "is deterministic" do
      expect(described_class.blake2b256("abc")).to eq(described_class.blake2b256("abc"))
    end

    it "changes with input" do
      expect(described_class.blake2b256("a")).not_to eq(described_class.blake2b256("b"))
    end
  end

  # ---------------------------------------------------------------------------
  # .siphash — basic smoke tests
  # ---------------------------------------------------------------------------

  describe ".siphash" do
    it "returns a 64-bit integer" do
      result = described_class.siphash(0, 0, 0, 0, 0)
      expect(result).to be_a(Integer)
      expect(result).to be >= 0
      expect(result).to be <= (1 << 64) - 1
    end

    it "is deterministic" do
      r1 = described_class.siphash(1, 2, 3, 4, 100)
      r2 = described_class.siphash(1, 2, 3, 4, 100)
      expect(r1).to eq(r2)
    end

    it "changes with nonce" do
      r1 = described_class.siphash(1, 2, 3, 4, 0)
      r2 = described_class.siphash(1, 2, 3, 4, 1)
      expect(r1).not_to eq(r2)
    end

    it "changes with keys" do
      r1 = described_class.siphash(0, 0, 0, 0, 42)
      r2 = described_class.siphash(1, 0, 0, 0, 42)
      expect(r1).not_to eq(r2)
    end
  end

  # ---------------------------------------------------------------------------
  # .verify_cycle — Grin C29 KAT (the make-or-break gate)
  # ---------------------------------------------------------------------------

  describe ".verify_cycle" do
    context "ACCEPT — Grin C29 KAT" do
      it "accepts the valid 42-cycle for header=(76-zeros + LE32(20))" do
        result = described_class.verify_cycle(
          keys:     KAT_KEYS,
          edgebits: KAT_EDGEBITS,
          cycle:    KAT_CYCLE
        )
        expect(result).to be(true),
          "KAT FAILED — siphash keying or cycle walk is wrong.\n" \
          "Keys: #{KAT_KEYS.map { |k| format("0x%016x", k) }.inspect}\n" \
          "First edge: #{format("0x%x", KAT_CYCLE[0])}\n" \
          "First U endpoint: #{format("0x%x", described_class.siphash(*KAT_KEYS, 2 * KAT_CYCLE[0]) & ((1 << 29) - 1))}\n" \
          "First V endpoint: #{format("0x%x", described_class.siphash(*KAT_KEYS, 2 * KAT_CYCLE[0] + 1) & ((1 << 29) - 1))}"
      end
    end

    context "REJECT — negative cases (cycle walk integrity)" do
      it "(a) rejects when first edge is mutated 0x48a9e2 → 0x48a9e1" do
        bad_cycle = KAT_CYCLE.dup
        bad_cycle[0] = 0x48a9e1  # one less than the valid value
        expect(described_class.verify_cycle(keys: KAT_KEYS, edgebits: KAT_EDGEBITS, cycle: bad_cycle)).to be(false)
      end

      it "(b) rejects non-ascending cycle (first two edges swapped)" do
        bad_cycle = KAT_CYCLE.dup
        bad_cycle[0], bad_cycle[1] = bad_cycle[1], bad_cycle[0]
        expect(described_class.verify_cycle(keys: KAT_KEYS, edgebits: KAT_EDGEBITS, cycle: bad_cycle)).to be(false)
      end

      it "(c) rejects cycle with a duplicate (first edge repeated)" do
        bad_cycle = KAT_CYCLE.dup
        bad_cycle[1] = bad_cycle[0]  # edge[0] == edge[1] → not strictly ascending
        expect(described_class.verify_cycle(keys: KAT_KEYS, edgebits: KAT_EDGEBITS, cycle: bad_cycle)).to be(false)
      end

      it "(d) rejects cycle with an edge >= N (first edge set to N)" do
        n = 1 << KAT_EDGEBITS
        bad_cycle = KAT_CYCLE.dup
        bad_cycle[0] = n  # exactly N — out of range
        # Must re-sort since N is likely > KAT_CYCLE.last; sort to keep ascending for early check
        bad_cycle = bad_cycle.sort
        expect(described_class.verify_cycle(keys: KAT_KEYS, edgebits: KAT_EDGEBITS, cycle: bad_cycle)).to be(false)
      end

      it "(e) rejects a 41-edge cycle (one short)" do
        expect(described_class.verify_cycle(keys: KAT_KEYS, edgebits: KAT_EDGEBITS, cycle: KAT_CYCLE[0, 41])).to be(false)
      end

      it "(e) rejects a 43-edge cycle (one extra)" do
        extra_cycle = KAT_CYCLE + [KAT_CYCLE.last + 2]  # keep ascending
        expect(described_class.verify_cycle(keys: KAT_KEYS, edgebits: KAT_EDGEBITS, cycle: extra_cycle)).to be(false)
      end

      it "(f) rejects an empty cycle" do
        expect(described_class.verify_cycle(keys: KAT_KEYS, edgebits: KAT_EDGEBITS, cycle: [])).to be(false)
      end

      it "(g) returns false (not raise) for a non-Integer cycle element (K-227)" do
        # A String edge at full proofsize length reaches the `edge >= n_nodes`
        # comparison, which used to raise ArgumentError. Malformed proof types
        # must return false, never raise (K-149 never-raise class).
        expect {
          expect(described_class.verify_cycle(
            keys: [1, 2, 3, 4], edgebits: 10, cycle: ["x", 2], proofsize: 2
          )).to be(false)
        }.not_to raise_error
      end
    end
  end

  # ---------------------------------------------------------------------------
  # .verify — public API path (end-to-end through salt → header → keys)
  # ---------------------------------------------------------------------------

  describe ".verify" do
    let(:params) { described_class.params(edgebits: KAT_EDGEBITS) }

    context "ACCEPT via public API (salt=76-zeros, header_nonce=20)" do
      it "accepts the Grin C29 KAT cycle with symbol keys" do
        result = described_class.verify(
          salt:   KAT_SALT,
          params: params,
          nonce:  { header_nonce: KAT_NONCE, cycle: KAT_CYCLE }
        )
        expect(result).to be(true),
          "Public API KAT FAILED — verify(salt:, params:, nonce:) rejected valid cycle"
      end

      it "accepts the KAT cycle with string keys in nonce hash" do
        result = described_class.verify(
          salt:   KAT_SALT,
          params: params,
          nonce:  { "header_nonce" => KAT_NONCE, "cycle" => KAT_CYCLE }
        )
        expect(result).to be(true)
      end

      it "accepts with string keys in params hash" do
        str_params = { "edgebits" => KAT_EDGEBITS, "proofsize" => 42, "target" => nil }
        result = described_class.verify(
          salt:   KAT_SALT,
          params: str_params,
          nonce:  { header_nonce: KAT_NONCE, cycle: KAT_CYCLE }
        )
        expect(result).to be(true)
      end
    end

    context "REJECT via public API — different keys (wrong header)" do
      it "(a) rejects when salt byte 0 is flipped to 1 (different keys)" do
        bad_salt = "\x01" + "\x00" * 75
        result = described_class.verify(
          salt:   bad_salt,
          params: params,
          nonce:  { header_nonce: KAT_NONCE, cycle: KAT_CYCLE }
        )
        expect(result).to be(false)
      end

      it "(a-nonce) rejects when header_nonce is changed to 21" do
        result = described_class.verify(
          salt:   KAT_SALT,
          params: params,
          nonce:  { header_nonce: 21, cycle: KAT_CYCLE }
        )
        expect(result).to be(false)
      end
    end

    context "REJECT via public API — bad cycle data" do
      it "(b) rejects when first cycle edge is mutated 0x48a9e2 → 0x48a9e1" do
        bad_cycle = KAT_CYCLE.dup
        bad_cycle[0] = 0x48a9e1
        result = described_class.verify(
          salt: KAT_SALT, params: params,
          nonce: { header_nonce: KAT_NONCE, cycle: bad_cycle }
        )
        expect(result).to be(false)
      end

      it "(c) rejects non-ascending cycle" do
        bad = KAT_CYCLE.dup
        bad[0], bad[1] = bad[1], bad[0]
        expect(described_class.verify(salt: KAT_SALT, params: params,
          nonce: { header_nonce: KAT_NONCE, cycle: bad })).to be(false)
      end

      it "(d) rejects cycle edge >= N" do
        n = 1 << KAT_EDGEBITS
        bad = (KAT_CYCLE[1..] + [n]).sort
        expect(described_class.verify(salt: KAT_SALT, params: params,
          nonce: { header_nonce: KAT_NONCE, cycle: bad })).to be(false)
      end

      it "(e) rejects 41-edge cycle" do
        expect(described_class.verify(salt: KAT_SALT, params: params,
          nonce: { header_nonce: KAT_NONCE, cycle: KAT_CYCLE[0, 41] })).to be(false)
      end

      it "(e) rejects 43-edge cycle" do
        extra = KAT_CYCLE + [KAT_CYCLE.last + 2]
        expect(described_class.verify(salt: KAT_SALT, params: params,
          nonce: { header_nonce: KAT_NONCE, cycle: extra })).to be(false)
      end
    end

    context "guard rails" do
      it "returns false for a non-Hash nonce" do
        expect(described_class.verify(salt: KAT_SALT, params: params, nonce: "bad")).to be(false)
      end

      it "returns false for a nonce missing the cycle key" do
        expect(described_class.verify(salt: KAT_SALT, params: params,
          nonce: { header_nonce: KAT_NONCE })).to be(false)
      end

      it "returns false (not raise) for a non-numeric header_nonce (K-227)" do
        # Integer("abc") used to raise ArgumentError while building the header.
        # A non-coercible header_nonce means a malformed proof → false, not raise.
        expect {
          expect(described_class.verify(salt: KAT_SALT, params: params,
            nonce: { header_nonce: "abc", cycle: KAT_CYCLE })).to be(false)
        }.not_to raise_error
      end

      it "returns false (not raise) for a non-Integer cycle element (K-227)" do
        # A String cycle element at matching proofsize reaches the in-range
        # comparison in verify_cycle, which used to raise ArgumentError.
        p2 = described_class.params(edgebits: 10, proofsize: 2)
        expect {
          expect(described_class.verify(salt: KAT_SALT, params: p2,
            nonce: { header_nonce: 0, cycle: ["x", 2] })).to be(false)
        }.not_to raise_error
      end
    end

    # -------------------------------------------------------------------------
    # Toy proofsize=12 cross-impl vector (edgebits=10)
    #
    # TOY MECHANISM DEMO — proofsize 12 at edgebits 10; NOT production difficulty.
    #
    # This vector was produced by the Python solver (solve_cuckoo.py) with:
    #   salt  = Base64.strict_decode64("cGFyaXR5IQ==")  # "parity!"
    #   edgebits = 10, proofsize = 12, header_nonce = 1
    #
    # Python cross-reference (must match):
    #   import hashlib, struct, base64
    #   salt = base64.b64decode("cGFyaXR5IQ==")
    #   header = salt + struct.pack("<I", 1)
    #   hashlib.blake2b(header, digest_size=32).hexdigest()
    #   => keys used for U/V computation
    # -------------------------------------------------------------------------
    context "ACCEPT — toy proofsize=12 cross-impl vector (edgebits=10, hn=1)" do
      TOY_EDGEBITS  = 10
      TOY_SALT_B64  = "cGFyaXR5IQ=="
      TOY_SALT      = Base64.strict_decode64(TOY_SALT_B64).freeze
      TOY_HN        = 1
      TOY_PROOFSIZE = 12
      TOY_CYCLE     = [12, 362, 383, 633, 694, 717, 849, 872, 934, 944, 948, 961].freeze

      it "accepts the 12-cycle produced by the Python solver via .verify" do
        result = described_class.verify(
          salt:   TOY_SALT,
          params: described_class.params(edgebits: TOY_EDGEBITS, proofsize: TOY_PROOFSIZE),
          nonce:  { header_nonce: TOY_HN, cycle: TOY_CYCLE }
        )
        expect(result).to be(true),
          "Proofsize=12 cross-impl vector FAILED — keying, siphash, or cycle walk is wrong"
      end

      it "accepts via .verify_cycle with pre-derived keys" do
        header = TOY_SALT + [TOY_HN].pack("V")
        keys   = described_class.blake2b256(header).unpack("Q<4")
        result = described_class.verify_cycle(
          keys:      keys,
          edgebits:  TOY_EDGEBITS,
          cycle:     TOY_CYCLE,
          proofsize: TOY_PROOFSIZE
        )
        expect(result).to be(true)
      end

      it "rejects the same cycle with wrong header_nonce" do
        result = described_class.verify(
          salt:   TOY_SALT,
          params: described_class.params(edgebits: TOY_EDGEBITS, proofsize: TOY_PROOFSIZE),
          nonce:  { header_nonce: TOY_HN + 1, cycle: TOY_CYCLE }
        )
        expect(result).to be(false)
      end

      it "rejects a truncated cycle (11 edges instead of 12)" do
        result = described_class.verify(
          salt:   TOY_SALT,
          params: described_class.params(edgebits: TOY_EDGEBITS, proofsize: TOY_PROOFSIZE),
          nonce:  { header_nonce: TOY_HN, cycle: TOY_CYCLE[0, 11] }
        )
        expect(result).to be(false)
      end

      it "rejects a mutated first edge" do
        bad_cycle = TOY_CYCLE.dup
        bad_cycle[0] = bad_cycle[0] + 1  # corrupt first edge
        result = described_class.verify(
          salt:   TOY_SALT,
          params: described_class.params(edgebits: TOY_EDGEBITS, proofsize: TOY_PROOFSIZE),
          nonce:  { header_nonce: TOY_HN, cycle: bad_cycle }
        )
        expect(result).to be(false)
      end
    end

    context "optional difficulty target" do
      it "accepts any valid cycle when target is nil (the default)" do
        p = described_class.params(edgebits: KAT_EDGEBITS, target: nil)
        result = described_class.verify(
          salt: KAT_SALT, params: p,
          nonce: { header_nonce: KAT_NONCE, cycle: KAT_CYCLE }
        )
        expect(result).to be(true)
      end

      it "accepts when target is 2^256 - 1 (maximum, everything passes)" do
        max_target = (1 << 256) - 1
        p = described_class.params(edgebits: KAT_EDGEBITS, target: max_target)
        result = described_class.verify(
          salt: KAT_SALT, params: p,
          nonce: { header_nonce: KAT_NONCE, cycle: KAT_CYCLE }
        )
        expect(result).to be(true)
      end

      it "accepts when a non-trivial target is set and the cycle-hash satisfies it" do
        # Realistic target-set-AND-passes path: derive the exact cycle-hash the
        # verifier computes (blake2b-256 of the sorted cycle edges as LE u64,
        # big-endian integer) and set target one above it — a specific 256-bit
        # value strictly between 0 and max that this proof genuinely clears.
        cycle_packed = KAT_CYCLE.sort.pack("Q<*")
        hash_int     = described_class.blake2b256(cycle_packed)
                                      .unpack("C*").reduce(0) { |acc, b| (acc << 8) | b }
        target       = hash_int + 1   # hash_int < target → passes the check
        expect(target).to be > 0
        expect(target).to be < (1 << 256)

        p = described_class.params(edgebits: KAT_EDGEBITS, target: target)
        result = described_class.verify(
          salt: KAT_SALT, params: p,
          nonce: { header_nonce: KAT_NONCE, cycle: KAT_CYCLE }
        )
        expect(result).to be(true)
      end

      it "rejects when target is 0 (nothing passes)" do
        p = described_class.params(edgebits: KAT_EDGEBITS, target: 0)
        result = described_class.verify(
          salt: KAT_SALT, params: p,
          nonce: { header_nonce: KAT_NONCE, cycle: KAT_CYCLE }
        )
        expect(result).to be(false)
      end
    end
  end
end
