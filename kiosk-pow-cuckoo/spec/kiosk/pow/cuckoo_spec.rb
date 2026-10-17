# frozen_string_literal: true

require 'spec_helper'
require 'base64'

# Known-answer vectors and short calls into the verifier.
module CuckooVectors
  # Grin Cuckatoo29 known-answer vector (C29, header nonce 20). The keys are
  # BLAKE2b-256(76 zero bytes + LE32(20)) read as LE u64, which reproduces
  # Grin's set_header_nonce(header = 80 zero bytes, nonce = 20). The cycle is
  # the unique valid 42-cycle for that header, from Grin's test suite.
  #
  # Python cross-reference:
  #   hashlib.blake2b(b"\x00"*76 + b"\x14\x00\x00\x00", digest_size=32).hexdigest()
  #   => "770129fe760558276ee7f431209beaf98f8607868c3063160e0d18fab03988b8"
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
    0x1c05d5b0,  0x1c0b9caa
  ].freeze
  KAT_BLAKE2B_HEX = '770129fe760558276ee7f431209beaf98f8607868c3063160e0d18fab03988b8'
  KAT_KEYS = Kiosk::Pow::Cuckoo.blake2b256(KAT_SALT + [KAT_NONCE].pack('V')).unpack('Q<4').freeze

  # Toy vector: proofsize 12 at edgebits 10, not production difficulty. The
  # Python solver (solve_cuckoo.py) made it from salt "parity!" and header nonce 1.
  TOY_EDGEBITS  = 10
  TOY_SALT      = Base64.strict_decode64('cGFyaXR5IQ==').freeze
  TOY_HN        = 1
  TOY_PROOFSIZE = 12
  TOY_CYCLE     = [12, 362, 383, 633, 694, 717, 849, 872, 934, 944, 948, 961].freeze

  def kat_cycle_valid?(cycle)
    Kiosk::Pow::Cuckoo.verify_cycle(keys: KAT_KEYS, edgebits: KAT_EDGEBITS, cycle:)
  end

  # `.verify` on the KAT, with any part replaced.
  def verify_kat(cycle: KAT_CYCLE, header_nonce: KAT_NONCE, salt: KAT_SALT, params: { edgebits: KAT_EDGEBITS })
    Kiosk::Pow::Cuckoo.verify(salt:, params: Kiosk::Pow::Cuckoo.params(**params), nonce: { header_nonce:, cycle: })
  end

  def verify_toy(cycle: TOY_CYCLE, header_nonce: TOY_HN)
    Kiosk::Pow::Cuckoo.verify(salt: TOY_SALT,
                              params: Kiosk::Pow::Cuckoo.params(edgebits: TOY_EDGEBITS, proofsize: TOY_PROOFSIZE),
                              nonce: { header_nonce:, cycle: })
  end

  # The KAT cycle with the edge at `index` replaced by `edge`.
  def kat_cycle_with(index, edge)
    KAT_CYCLE.dup.tap { |cycle| cycle[index] = edge }
  end

  def kat_cycle_swapped
    KAT_CYCLE.dup.tap { |cycle| cycle[0], cycle[1] = cycle[1], cycle[0] }
  end

  def kat_cycle_hash
    Kiosk::Pow::Cuckoo.blake2b256(KAT_CYCLE.sort.pack('Q<*')).unpack('C*').reduce(0) { |acc, byte| (acc << 8) | byte }
  end
end

RSpec.describe Kiosk::Pow::Cuckoo do
  describe 'NAME' do
    it "is 'cuckatoo'" do
      expect(described_class::NAME).to eq('cuckatoo')
    end
  end

  describe '.params' do
    it 'returns a hash with edgebits, proofsize, and target' do
      expect(described_class.params(edgebits: 29)).to include(edgebits: 29, proofsize: 42, target: nil)
    end

    it 'accepts custom proofsize and target' do
      expect(described_class.params(edgebits: 19, proofsize: 42, target: 1234))
        .to eq({ edgebits: 19, proofsize: 42, target: 1234 })
    end
  end
end

# Cross-referenced against Python hashlib.blake2b(…, digest_size=32).
RSpec.describe Kiosk::Pow::Cuckoo, '.blake2b256' do
  it 'matches Python hashlib.blake2b for empty input' do
    expect(described_class.blake2b256(''.b).unpack1('H*'))
      .to eq('0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8')
  end

  it 'matches Python hashlib.blake2b for the KAT header (76 zeros + LE32(20))' do
    header = CuckooVectors::KAT_SALT + [CuckooVectors::KAT_NONCE].pack('V')
    expect(described_class.blake2b256(header).unpack1('H*')).to eq(CuckooVectors::KAT_BLAKE2B_HEX)
  end

  it 'returns 32 raw bytes' do
    expect(described_class.blake2b256('hello').bytesize).to eq(32)
  end

  it 'is deterministic' do
    expect(described_class.blake2b256('abc')).to eq(described_class.blake2b256('abc'))
  end

  it 'changes with input' do
    expect(described_class.blake2b256('a')).not_to eq(described_class.blake2b256('b'))
  end
end

RSpec.describe Kiosk::Pow::Cuckoo, '.siphash' do
  it 'returns a 64-bit integer' do
    result = described_class.siphash(0, 0, 0, 0, 0)
    expect(result).to be_a(Integer)
    expect(result).to be >= 0
    expect(result).to be <= (1 << 64) - 1
  end

  it 'is deterministic' do
    expect(described_class.siphash(1, 2, 3, 4, 100)).to eq(described_class.siphash(1, 2, 3, 4, 100))
  end

  it 'changes with nonce' do
    expect(described_class.siphash(1, 2, 3, 4, 0)).not_to eq(described_class.siphash(1, 2, 3, 4, 1))
  end

  it 'changes with keys' do
    expect(described_class.siphash(0, 0, 0, 0, 42)).not_to eq(described_class.siphash(1, 0, 0, 0, 42))
  end
end

RSpec.describe Kiosk::Pow::Cuckoo, '.verify_cycle on the Grin C29 KAT' do
  include CuckooVectors

  it 'accepts the valid 42-cycle for header=(76-zeros + LE32(20))' do
    keys  = CuckooVectors::KAT_KEYS
    first = CuckooVectors::KAT_CYCLE[0]
    mask  = (1 << 29) - 1
    expect(kat_cycle_valid?(CuckooVectors::KAT_CYCLE)).to be(true),
                                                          "KAT FAILED — siphash keying or cycle walk is wrong.\n" \
                                                          "Keys: #{keys.map { |k| format('0x%016x', k) }.inspect}\n" \
                                                          "First edge: #{format('0x%x', first)}\n" \
                                                          "First U endpoint: #{format('0x%x', described_class.siphash(*keys, 2 * first) & mask)}\n" \
                                                          "First V endpoint: #{format('0x%x', described_class.siphash(*keys, (2 * first) + 1) & mask)}"
  end
end

RSpec.describe Kiosk::Pow::Cuckoo, '.verify_cycle rejections' do
  include CuckooVectors

  it '(a) rejects when first edge is mutated 0x48a9e2 → 0x48a9e1' do
    expect(kat_cycle_valid?(kat_cycle_with(0, 0x48a9e1))).to be(false)
  end

  it '(b) rejects non-ascending cycle (first two edges swapped)' do
    expect(kat_cycle_valid?(kat_cycle_swapped)).to be(false)
  end

  it '(c) rejects cycle with a duplicate (first edge repeated)' do
    expect(kat_cycle_valid?(kat_cycle_with(1, CuckooVectors::KAT_CYCLE[0]))).to be(false)
  end

  # An edge of exactly N is out of range; the sort keeps the cycle ascending.
  it '(d) rejects cycle with an edge >= N (first edge set to N)' do
    expect(kat_cycle_valid?(kat_cycle_with(0, 1 << CuckooVectors::KAT_EDGEBITS).sort)).to be(false)
  end

  it '(e) rejects a 41-edge cycle (one short)' do
    expect(kat_cycle_valid?(CuckooVectors::KAT_CYCLE[0, 41])).to be(false)
  end

  it '(e) rejects a 43-edge cycle (one extra)' do
    expect(kat_cycle_valid?(CuckooVectors::KAT_CYCLE + [CuckooVectors::KAT_CYCLE.last + 2])).to be(false)
  end

  it '(f) rejects an empty cycle' do
    expect(kat_cycle_valid?([])).to be(false)
  end
end

RSpec.describe Kiosk::Pow::Cuckoo, '.verify_cycle on a malformed cycle' do
  # A String edge at full proofsize length reaches the range comparison.
  it '(g) returns false (not raise) for a non-Integer cycle element' do
    expect do
      expect(described_class.verify_cycle(keys: [1, 2, 3, 4], edgebits: 10, cycle: ['x', 2], proofsize: 2)).to be(false)
    end.not_to raise_error
  end
end

RSpec.describe Kiosk::Pow::Cuckoo, '.verify accepts the KAT' do
  include CuckooVectors

  it 'accepts the Grin C29 KAT cycle with symbol keys' do
    expect(verify_kat).to be(true), 'Public API KAT FAILED — verify(salt:, params:, nonce:) rejected valid cycle'
  end

  it 'accepts the KAT cycle with string keys in nonce hash' do
    nonce = { 'header_nonce' => CuckooVectors::KAT_NONCE, 'cycle' => CuckooVectors::KAT_CYCLE }
    expect(described_class.verify(salt: CuckooVectors::KAT_SALT,
                                  params: described_class.params(edgebits: CuckooVectors::KAT_EDGEBITS),
                                  nonce:)).to be(true)
  end

  it 'accepts with string keys in params hash' do
    params = { 'edgebits' => CuckooVectors::KAT_EDGEBITS, 'proofsize' => 42, 'target' => nil }
    expect(described_class.verify(salt: CuckooVectors::KAT_SALT, params:,
                                  nonce: { header_nonce: CuckooVectors::KAT_NONCE, cycle: CuckooVectors::KAT_CYCLE }))
      .to be(true)
  end
end

RSpec.describe Kiosk::Pow::Cuckoo, '.verify rejects a different header' do
  include CuckooVectors

  it '(a) rejects when salt byte 0 is flipped to 1 (different keys)' do
    expect(verify_kat(salt: "\x01#{"\x00" * 75}")).to be(false)
  end

  it '(a-nonce) rejects when header_nonce is changed to 21' do
    expect(verify_kat(header_nonce: 21)).to be(false)
  end
end

RSpec.describe Kiosk::Pow::Cuckoo, '.verify rejects bad cycle data' do
  include CuckooVectors

  it '(b) rejects when first cycle edge is mutated 0x48a9e2 → 0x48a9e1' do
    expect(verify_kat(cycle: kat_cycle_with(0, 0x48a9e1))).to be(false)
  end

  it '(c) rejects non-ascending cycle' do
    expect(verify_kat(cycle: kat_cycle_swapped)).to be(false)
  end

  it '(d) rejects cycle edge >= N' do
    expect(verify_kat(cycle: (CuckooVectors::KAT_CYCLE[1..] + [1 << CuckooVectors::KAT_EDGEBITS]).sort)).to be(false)
  end

  it '(e) rejects 41-edge cycle' do
    expect(verify_kat(cycle: CuckooVectors::KAT_CYCLE[0, 41])).to be(false)
  end

  it '(e) rejects 43-edge cycle' do
    expect(verify_kat(cycle: CuckooVectors::KAT_CYCLE + [CuckooVectors::KAT_CYCLE.last + 2])).to be(false)
  end
end

RSpec.describe Kiosk::Pow::Cuckoo, '.verify guard rails' do
  include CuckooVectors

  let(:params) { described_class.params(edgebits: CuckooVectors::KAT_EDGEBITS) }

  it 'returns false for a non-Hash nonce' do
    expect(described_class.verify(salt: CuckooVectors::KAT_SALT, params:, nonce: 'bad')).to be(false)
  end

  it 'returns false for a nonce missing the cycle key' do
    expect(described_class.verify(salt: CuckooVectors::KAT_SALT, params:,
                                  nonce: { header_nonce: CuckooVectors::KAT_NONCE })).to be(false)
  end

  it 'returns false (not raise) for a non-numeric header_nonce' do
    expect { expect(verify_kat(header_nonce: 'abc')).to be(false) }.not_to raise_error
  end

  # A String cycle element at matching proofsize reaches the range comparison.
  it 'returns false (not raise) for a non-Integer cycle element' do
    expect do
      expect(verify_kat(params: { edgebits: 10, proofsize: 2 }, header_nonce: 0, cycle: ['x', 2])).to be(false)
    end.not_to raise_error
  end

  # The control that the guards above do not reject a VALID proof.
  it 'answers the same as the sibling Equihash backend does for its matching shapes' do
    expect(verify_kat).to be(true)
  end
end

# A malformed proof or malformed params answer false, as the Equihash backend
# does: a raise would reach the wire as a 500, not the 403 a bad proof earns.
# The first two cycle shapes come from the caller of an unauthenticated
# registration; the rest are operator params.
RSpec.describe Kiosk::Pow::Cuckoo, '.verify on malformed input' do
  {
    'params missing edgebits' => [{ proofsize: 42 }, { header_nonce: 1, cycle: [1] }],
    'params that is a String' => ['edgebits=19', { header_nonce: 1, cycle: [1] }],
    'params that is nil' => [nil, { header_nonce: 1, cycle: [1] }],
    'a non-numeric edgebits' => [{ edgebits: 'abc', proofsize: 4 }, { header_nonce: 1, cycle: [1] }],
    'a non-numeric proofsize' => [{ edgebits: 19, proofsize: 'abc' }, { header_nonce: 1, cycle: [1] }],
    'a non-numeric target' => [{ edgebits: 19, proofsize: 1, target: 'abc' }, { header_nonce: 1, cycle: [1] }],
    'a cycle that is an Integer' => [{ edgebits: 19, proofsize: 1 }, { header_nonce: 1, cycle: 7 }],
    'a cycle that is a matching String' => [{ edgebits: 19, proofsize: 4 }, { header_nonce: 1, cycle: 'abcd' }]
  }.each do |label, (bad_params, bad_nonce)|
    it "returns false (not raise) for #{label}" do
      expect do
        expect(described_class.verify(salt: CuckooVectors::KAT_SALT, params: bad_params, nonce: bad_nonce)).to be(false)
      end.not_to raise_error
    end
  end
end

RSpec.describe Kiosk::Pow::Cuckoo, '.verify on the toy proofsize-12 vector (edgebits 10)' do
  include CuckooVectors

  it 'accepts the 12-cycle produced by the Python solver via .verify' do
    expect(verify_toy).to be(true), 'Proofsize=12 cross-impl vector FAILED — keying, siphash, or cycle walk is wrong'
  end

  it 'accepts via .verify_cycle with pre-derived keys' do
    keys = described_class.blake2b256(CuckooVectors::TOY_SALT + [CuckooVectors::TOY_HN].pack('V')).unpack('Q<4')
    expect(described_class.verify_cycle(keys:, edgebits: CuckooVectors::TOY_EDGEBITS,
                                        cycle: CuckooVectors::TOY_CYCLE, proofsize: CuckooVectors::TOY_PROOFSIZE))
      .to be(true)
  end

  it 'rejects the same cycle with wrong header_nonce' do
    expect(verify_toy(header_nonce: CuckooVectors::TOY_HN + 1)).to be(false)
  end

  it 'rejects a truncated cycle (11 edges instead of 12)' do
    expect(verify_toy(cycle: CuckooVectors::TOY_CYCLE[0, 11])).to be(false)
  end

  it 'rejects a mutated first edge' do
    expect(verify_toy(cycle: [CuckooVectors::TOY_CYCLE[0] + 1] + CuckooVectors::TOY_CYCLE[1..])).to be(false)
  end
end

RSpec.describe Kiosk::Pow::Cuckoo, '.verify with a difficulty target' do
  include CuckooVectors

  it 'accepts any valid cycle when target is nil (the default)' do
    expect(verify_kat(params: { edgebits: CuckooVectors::KAT_EDGEBITS, target: nil })).to be(true)
  end

  it 'accepts when target is 2^256 - 1 (maximum, everything passes)' do
    expect(verify_kat(params: { edgebits: CuckooVectors::KAT_EDGEBITS, target: (1 << 256) - 1 })).to be(true)
  end

  # The target is one above the cycle hash the verifier computes: a 256-bit
  # value strictly between 0 and the maximum that this proof clears.
  it 'accepts when a non-trivial target is set and the cycle-hash satisfies it' do
    target = kat_cycle_hash + 1
    expect(target).to be_positive
    expect(target).to be < (1 << 256)
    expect(verify_kat(params: { edgebits: CuckooVectors::KAT_EDGEBITS, target: })).to be(true)
  end

  it 'rejects when target is 0 (nothing passes)' do
    expect(verify_kat(params: { edgebits: CuckooVectors::KAT_EDGEBITS, target: 0 })).to be(false)
  end
end
