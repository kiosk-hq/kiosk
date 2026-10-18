# frozen_string_literal: true

require 'spec_helper'
require 'json'

# Known-answer vectors and short calls into the verifier.
module EquihashKats
  # (n=8, k=1): n_div=4, proofsize=2, seed "kat" + LE32(0). Python blake2b gives
  # first byte 0x9e for both index 2 and index 10, so the pair XORs to zero.
  KAT_SALT = 'kat'.b

  # Multi-level KATs from the reference Wagner solver, header_nonce 0. Indices
  # are in Zcash canonical (subtree) order, not globally sorted: at each tree
  # node the left half's first index precedes the right half's. The leaves do
  # not share a prefix; each level's block cancels by XOR.
  MULTI_SALT = 'kiosk-eqx-kat-01'.b

  # The frozen production-parameter solution (salt "kiosk-eqx-kat-01", n=168,
  # k=7, header_nonce 0) from solve.py, in canonical (subtree) order. It pins the
  # verifier at the shipped default parameters.
  PROD_INDICES = [
    35_635, 443_602, 769_922, 2_841_204, 288_650, 2_534_367, 3_711_384, 4_167_287,
    439_322, 3_579_870, 3_884_016, 4_011_474, 1_469_807, 2_859_441, 1_582_951, 2_663_283,
    175_258, 904_564, 2_551_933, 3_478_559, 2_097_074, 2_914_645, 3_026_485, 3_645_933,
    326_539, 3_134_338, 1_410_867, 3_946_408, 1_215_314, 2_610_863, 1_729_482, 2_563_633,
    215_557, 1_365_296, 3_286_033, 3_379_331, 1_092_666, 2_048_436, 1_956_659, 4_083_619,
    327_630, 966_319, 546_923, 3_597_822, 1_019_737, 3_289_324, 2_515_996, 4_102_785,
    352_766, 2_643_465, 2_237_387, 3_118_040, 1_365_775, 3_292_860, 1_484_813, 2_325_158,
    1_130_131, 3_785_225, 1_311_199, 1_689_016, 1_154_546, 2_027_634, 2_238_579, 2_294_173,
    47_664, 1_747_214, 1_924_004, 2_999_276, 2_036_646, 2_481_260, 2_187_884, 3_492_692,
    1_006_856, 1_260_610, 1_570_131, 3_646_554, 1_388_645, 2_876_691, 2_128_978, 2_588_422,
    367_435, 513_091, 3_105_269, 4_005_382, 489_985, 629_292, 2_672_040, 2_928_191,
    367_906, 2_335_214, 761_171, 3_386_820, 681_939, 2_064_865, 1_410_874, 1_730_962,
    219_306, 4_024_412, 1_712_945, 3_300_801, 719_958, 3_009_238, 1_383_878, 2_994_505,
    417_321, 3_362_644, 2_678_745, 2_792_851, 2_071_420, 2_778_845, 2_441_747, 4_028_940,
    220_716, 2_282_797, 1_287_422, 1_739_283, 1_064_154, 3_198_198, 3_579_075, 3_590_378,
    228_235, 2_335_503, 1_297_479, 3_907_179, 1_108_349, 2_972_099, 3_417_182, 3_877_732
  ].freeze

  # `.verify` on the (n=8, k=1) KAT, with the nonce replaced.
  def verify_kat(nonce = { indices: [2, 10] }, salt: KAT_SALT, params: { n: 8, k: 1 })
    Kiosk::Pow::Equihash.verify(salt:, params:, nonce:)
  end

  def verify_multi(indices, params)
    Kiosk::Pow::Equihash.verify(salt: MULTI_SALT, params:, nonce: { indices: })
  end

  # `.verify` with a throwaway salt and 128 ascending indices, for parameter checks.
  def verify_params(params, indices: (0...128).to_a)
    Kiosk::Pow::Equihash.verify(salt: 'x'.b, params:, nonce: { indices: })
  end

  # The first byte of the leaf hash for `index` under `salt` and header_nonce 0.
  def leaf_byte(salt, index)
    Kiosk::Pow::Blake2b.digest256(salt + [0].pack('V') + [index].pack('Q<')).getbyte(0)
  end
end

RSpec.describe Kiosk::Pow::Equihash do
  it "is 'equihash'" do
    expect(described_class::NAME).to eq('equihash')
  end

  it 'are the benchmark-chosen defaults (168, 7)' do
    expect(described_class::DEFAULT_N).to eq(168)
    expect(described_class::DEFAULT_K).to eq(7)
  end

  it 'returns n:168, k:7 by default' do
    expect(described_class.params).to eq({ n: 168, k: 7 })
  end

  it 'accepts custom n and k' do
    expect(described_class.params(n: 200, k: 9)).to eq({ n: 200, k: 9 })
  end

  # Consumers shell out to this path instead of reaching into the gem by a
  # checkout-relative path, so it must name an existing file in the gem root.
  it 'returns the absolute path of an existing solve.py inside the gem root' do
    path = described_class.solver_path
    expect(path).to eq(File.expand_path(path))
    expect(File.file?(path)).to be(true)
    expect(path).to eq(File.join(File.expand_path('../../..', __dir__), 'solve.py'))
  end
end

RSpec.describe Kiosk::Pow::Equihash, '.verify on the (n=8, k=1) KAT' do
  include EquihashKats

  it 'KAT: the constructed pair XORs to zero' do
    expect(leaf_byte(EquihashKats::KAT_SALT, 2) ^ leaf_byte(EquihashKats::KAT_SALT, 10)).to eq(0), 'KAT construction is wrong'
  end

  it 'ACCEPT — valid KAT (n=8,k=1, indices [2,10])' do
    expect(verify_kat).to be(true)
  end

  it 'ACCEPT — valid KAT with string keys in nonce' do
    expect(verify_kat({ 'indices' => [2, 10] })).to be(true)
  end

  it 'ACCEPT — valid KAT with string keys in params' do
    expect(verify_kat(params: { 'n' => 8, 'k' => 1 })).to be(true)
  end

  it 'REJECT — wrong salt' do
    expect(verify_kat(salt: 'bad'.b)).to be(false)
  end
end

RSpec.describe Kiosk::Pow::Equihash, '.verify on multi-level KATs (k >= 2)' do
  include EquihashKats

  it 'ACCEPT — valid k=2 KAT (n=24, canonical/tree order)' do
    expect(verify_multi([29, 653, 113, 572], { n: 24, k: 2 })).to be(true)
  end

  it 'ACCEPT — valid k=3 KAT (n=32, canonical/tree order)' do
    expect(verify_multi([31, 833, 279, 285, 147, 676, 596, 738], { n: 32, k: 3 })).to be(true)
  end

  # Sorting regroups (29,653)(113,572) into (29,113)(572,653), which are not the
  # colliding pairs, so the level-0 XOR no longer cancels.
  it 'REJECT — the SAME k=2 solution globally sorted (breaks the tree pairing)' do
    expect(verify_multi([29, 113, 572, 653], { n: 24, k: 2 })).to be(false)
  end

  it 'REJECT — k=2 with one mutated index (XOR no longer cancels)' do
    expect(verify_multi([29, 653, 113, 573], { n: 24, k: 2 })).to be(false)
  end

  # The right subtree (113,572) placed before the left (29,653): the XOR still
  # cancels, but left.first (113) > right.first (29) breaks the subtree order.
  it 'REJECT — k=2 canonical values but subtree order violated (halves swapped)' do
    expect(verify_multi([113, 572, 29, 653], { n: 24, k: 2 })).to be(false)
  end
end

# A malformed nonce answers false and never raises.
RSpec.describe Kiosk::Pow::Equihash, '.verify on malformed indices' do
  include EquihashKats

  {
    'REJECT — mutated index (2→3)' => [3, 10],
    'REJECT — wrong count (3 indices, k=1 expects 2)' => [2, 10, 42],
    'REJECT — too few indices' => [2],
    'REJECT — empty indices' => [],
    'REJECT — non-ascending [10, 2]' => [10, 2],
    'REJECT — duplicate [2, 2]' => [2, 2],
    'REJECT — float in indices' => [2.0, 10],
    'REJECT — nil element in indices (returns false, does not raise)' => [nil, 10],
    'REJECT — non-numeric string element in indices (returns false, does not raise)' => ['x', 10],
    'REJECT — :indices is not an Array' => 'nope'
  }.each do |label, indices|
    it label do
      expect(verify_kat({ indices: })).to be(false)
    end
  end

  { 'REJECT — nonce is nil' => nil, 'REJECT — nonce is not a Hash' => 'bad', 'REJECT — nonce missing :indices' => {} }
    .each do |label, nonce|
      it label do
        expect(verify_kat(nonce)).to be(false)
      end
    end
end

# header_nonce is client-supplied and a u32: `pack("V")` truncates mod 2**32, so
# without the range bound 0, 2**32 and -(2**32) would seed identically.
RSpec.describe Kiosk::Pow::Equihash, '.verify with a header_nonce' do
  include EquihashKats

  {
    'REJECT — different header_nonce changes seed' => 1,
    'REJECT — non-coercible header_nonce type (Array) returns false, does not raise' => [1],
    'REJECT — Hash header_nonce returns false, does not raise' => { 'x' => 1 },
    'REJECT — header_nonce == 2**32 (the truncating alias of 0)' => 2**32,
    'REJECT — header_nonce == -(2**32) (the negative truncating alias of 0)' => -(2**32),
    'REJECT — a negative header_nonce' => -1
  }.each do |label, header_nonce|
    it label do
      expect(verify_kat({ indices: [2, 10], header_nonce: })).to be(false)
    end
  end

  it 'REJECT — non-numeric string header_nonce (returns false, does not raise)' do
    expect(verify_kat({ 'indices' => [2, 10], 'header_nonce' => 'abc' })).to be(false)
  end

  it 'ACCEPT — header_nonce=0 same as default' do
    expect(verify_kat({ indices: [2, 10], header_nonce: 0 })).to be(true)
  end

  # 2**32 - 1 and 2**32 are one apart, and only the second is out of range.
  it 'ACCEPT — the largest legal header_nonce is in range (2**32 - 1)' do
    expect(described_class::MAX_HEADER_NONCE).to eq(4_294_967_296)
    expect(4_294_967_295).to be < described_class::MAX_HEADER_NONCE
  end
end

# (n=8, k=2): n_div=2, proofsize=4. Python blake2b first bytes for indices
# 0, 5, 33, 84 are 0xbf, 0xba, 0xbc, 0xb9: the top 2 bits all 0b10, the top 4
# all 0b1011, and the XOR of all four is 0.
RSpec.describe Kiosk::Pow::Equihash, '.verify on the (n=8, k=2) KAT' do
  include EquihashKats

  it 'KAT (8,2): indices XOR to zero and form a valid collision tree' do
    expect([0, 5, 33, 84].map { |i| leaf_byte('kat'.b, i) }.reduce(:^)).to eq(0), 'KAT (8,2) XOR is wrong'
  end

  it 'ACCEPT — valid KAT (n=8,k=2, indices [0,5,33,84])' do
    expect(verify_kat({ indices: [0, 5, 33, 84] }, params: { n: 8, k: 2 })).to be(true)
  end
end

RSpec.describe Kiosk::Pow::Equihash, '.verify on the production params (n=168, k=7) KAT' do
  def verify_prod(indices)
    described_class.verify(salt: EquihashKats::MULTI_SALT, params: described_class.params(n: 168, k: 7), nonce: { indices: })
  end

  it 'ACCEPT — the frozen reference solution (canonical order)' do
    expect(verify_prod(EquihashKats::PROD_INDICES)).to be(true)
  end

  it 'REJECT — the same solution globally sorted (breaks tree pairing)' do
    expect(verify_prod(EquihashKats::PROD_INDICES.sort)).to be(false)
  end

  it 'REJECT — one mutated index (XOR no longer cancels)' do
    expect(verify_prod(EquihashKats::PROD_INDICES.dup.tap { |ix| ix[127] += 1 })).to be(false)
  end
end

# Only an operator misconfiguration reaches these (the challenge re-derives its
# params from live config), and each one answers false: never a crash, and never
# a vacuous true that accepts a proof nobody supplied.
RSpec.describe Kiosk::Pow::Equihash, '.verify on degenerate parameters' do
  include EquihashKats

  # `1 << -5` is 0, so an empty indices array would pass the length check.
  it 'REJECT — negative k (was: NoMethodError on an empty stack)' do
    expect(verify_params({ n: 168, k: -5 }, indices: [])).to be(false)
  end

  # `n_bytes = 0` would make every leaf 0, so every XOR would cancel.
  it 'REJECT — n = 0 (was: a VACUOUS TRUE for 128 arbitrary indices)' do
    expect(verify_params({ n: 0, k: 7 })).to be(false)
  end

  it 'REJECT — negative n (was: NoMethodError, byteslice(0, -1) is nil)' do
    expect(verify_params({ n: -8, k: 7 })).to be(false)
  end

  it 'REJECT — n below one byte (n = 4: same vacuous leaf as n = 0)' do
    expect(verify_params({ n: 4, k: 7 })).to be(false)
  end

  # `byteslice` returns only the 32 bytes that exist, so the tree levels would
  # stop being checked. The answer follows from the parameters, not the proof.
  it 'REJECT — n wider than the digest (n = 512 > 256 bits of BLAKE2b-256)' do
    expect(verify_params({ n: 512, k: 7 })).to be(false)
  end
end

RSpec.describe Kiosk::Pow::Equihash, '.verify on unusable parameters' do
  include EquihashKats

  # With n_div = 0 every level check passes, and only a one-byte collision is left.
  it 'REJECT — zero bits per level (n = 8, k = 8 ⇒ n_div = 0)' do
    expect(verify_params({ n: 8, k: 8 }, indices: (0...256).to_a)).to be(false)
  end

  it 'REJECT — a non-numeric n (was: ArgumentError out of Integer())' do
    expect(verify_params({ n: 'abc', k: 7 })).to be(false)
  end

  it 'REJECT — params that are not a Hash at all (was: NoMethodError)' do
    expect(verify_params(nil)).to be(false)
  end
end

# k = 0 is degenerate but defined: no tree, and the root check is the only one.
# The guard must refuse k < 0 and keep k = 0, so this is a positive proof.
RSpec.describe Kiosk::Pow::Equihash, '.verify on edge parameters that stay accepted' do
  include EquihashKats

  it 'ACCEPTS k = 0 — no tree, the root check is the only one' do
    index = (0...4096).find { |i| leaf_byte('k0'.b, i).zero? }
    expect(index).not_to be_nil, 'no 8-bit-zero leaf in the first 4096 — widen the search'
    expect(described_class.verify(salt: 'k0'.b, params: { n: 8, k: 0 }, nonce: { indices: [index] })).to be(true)
  end

  # 8 % 3 == 2, and that KAT is a real solution: a divisibility rule would
  # narrow the accepted set.
  it 'ACCEPTS n % (k + 1) != 0 — the hand-computed (n=8, k=2) KAT' do
    expect(verify_kat({ indices: [0, 5, 33, 84] }, params: { n: 8, k: 2 })).to be(true)
  end
end

# `.valid_params?` asks the `.verify` parameter check before a challenge is
# minted, so a gate can refuse at the source. It answers for the same set.
module EquihashParamSets
  REJECTED = {
    'negative k' => { n: 168, k: -5 },
    'n = 0' => { n: 0, k: 7 },
    'negative n' => { n: -8, k: 7 },
    'n below one byte' => { n: 4, k: 7 },
    'n wider than the digest' => { n: 512, k: 7 },
    'zero bits per level' => { n: 8, k: 8 },
    'a non-numeric n' => { n: 'abc', k: 7 },
    'params that are not a Hash' => nil
  }.freeze

  ACCEPTED = {
    'the shipped default' => { n: 168, k: 7 },
    'the KAT parameters' => { n: 8, k: 2 },
    'k = 0' => { n: 8, k: 0 },
    'string keys off JSON' => { 'n' => 168, 'k' => 7 },
    'string values off JSON' => { n: '168', k: '7' },
    'an empty Hash (both members default)' => {}
  }.freeze
end

RSpec.describe Kiosk::Pow::Equihash, '.valid_params?' do
  include EquihashKats

  EquihashParamSets::REJECTED.each do |label, params|
    it "REJECTS #{label}" do
      expect(described_class.valid_params?(params)).to be(false)
    end
  end

  EquihashParamSets::ACCEPTED.each do |label, params|
    it "ACCEPTS #{label}" do
      expect(described_class.valid_params?(params)).to be(true)
    end
  end

  # `.verify` calls `.valid_params?`, so this fails only if one stops asking
  # the other: a well-formed nonce cannot rescue a refused parameter set.
  it "agrees with verify's Step 0 on every rejected set — one owner, no drift" do
    EquihashParamSets::REJECTED.each_value { |params| expect(verify_params(params)).to be(false) }
  end
end

RSpec.describe Kiosk::Pow::Equihash, '.verify at the default params (n=168, k=7)' do
  include EquihashKats

  let(:big_params) { described_class.params }

  it 'REJECT — 127 indices (expect 128)' do
    expect(verify_params(big_params, indices: (0...127).to_a)).to be(false)
  end

  it 'REJECT — 129 indices (expect 128)' do
    expect(verify_params(big_params, indices: (0...129).to_a)).to be(false)
  end

  it 'REJECT — non-ascending (first two swapped)' do
    expect(verify_params(big_params, indices: [1, 0, *(2...128)])).to be(false)
  end

  it 'REJECT — duplicate at end' do
    expect(verify_params(big_params, indices: [*(0...127), 126])).to be(false)
  end
end

# Counts the BLAKE2b calls one `.verify` makes. The count calls through, so the
# verdict is the real one.
module EquihashHashCount
  def verify_counting(indices, params: Kiosk::Pow::Equihash.params, salt: EquihashKats::MULTI_SALT, extra: {})
    count = 0
    allow(Kiosk::Pow::Blake2b).to receive(:digest256).and_wrap_original do |original, data|
      count += 1
      original.call(data)
    end
    [Kiosk::Pow::Equihash.verify(salt:, params:, nonce: { indices: }.merge(extra)), count]
  end
end

# `.verify` runs on an unauthenticated registration, so the price of rejecting
# rubbish is a security property: a wrong proof must not cost what a right one
# costs. These examples count BLAKE2b calls instead of measuring time.
RSpec.describe Kiosk::Pow::Equihash, 'cost of rejecting an invalid proof' do
  include EquihashHashCount

  it 'hashes NOTHING when the indices are not in canonical subtree order' do
    expect(verify_counting((0...128).to_a.shuffle(random: Random.new(7)))).to eq([false, 0])
  end

  # The out-of-range index stays the largest, so the order still holds.
  it 'hashes NOTHING when an index is out of u64 range' do
    expect(verify_counting([*(0...127), (1 << 64) + 5])).to eq([false, 0])
  end

  it 'hashes NOTHING when count, type or distinctness fails' do
    expect(verify_counting((0...127).to_a).last).to eq(0)
    expect(verify_counting((0...127).to_a + ['x']).last).to eq(0)
    expect(verify_counting((0...127).to_a + [126]).last).to eq(0)
  end

  it 'hashes NOTHING when header_nonce is not coercible' do
    expect(verify_counting((0...128).to_a, extra: { header_nonce: 'abc' }).last).to eq(0)
  end

  # 0..127 ascending passes count, type, range, distinctness and every
  # canonical-order comparison; only the hashes can reject it.
  it 'stops after ONE sibling pair (2 hashes) on structurally clean rubbish' do
    expect(verify_counting((0...128).to_a)).to eq([false, 2])
  end
end

RSpec.describe Kiosk::Pow::Equihash, 'cost of verifying the production KAT' do
  include EquihashHashCount

  it 'stops after ONE sibling pair on a real solution that was globally sorted' do
    expect(verify_counting(EquihashKats::PROD_INDICES.sort)).to eq([false, 2])
  end

  it 'still hashes every leaf for a VALID proof (the toll is not weakened)' do
    expect(verify_counting(EquihashKats::PROD_INDICES)).to eq([true, 128])
  end

  # `pack("Q<")` truncates mod 2**64, so without the range bound one solution
  # would have 2**k spendable spellings.
  it 'rejects a valid solution with 2**64 added to an index, without hashing' do
    expect(verify_counting(EquihashKats::PROD_INDICES.dup.tap { |ix| ix[1] += (1 << 64) })).to eq([false, 0])
  end
end

# Toy fixture (salt "k540-dfs", n=8, k=3, indices 0..7): both level-0 pairs
# cancel their 2 bits, but the height-2 node over leaves 0-3 does not cancel
# its 4. A verifier that folds the tree hashes 4 leaves; one that checks all of
# level 0 first hashes 8. So an attacker who wants the full hash loop must carry
# an almost complete solution.
RSpec.describe Kiosk::Pow::Equihash, 'cost of a proof that fails at a tree node' do
  include EquihashKats
  include EquihashHashCount

  it 'stops at the first failing tree NODE, not the first failing pair' do
    salt   = 'k540-dfs'.b
    leaves = (0...8).map { |i| leaf_byte(salt, i) }
    # The premises, so the fixture cannot rot into a vacuous pass.
    expect((leaves[0] ^ leaves[1]) >> 6).to eq(0), 'pair (0,1) must cancel 2 bits'
    expect((leaves[2] ^ leaves[3]) >> 6).to eq(0), 'pair (2,3) must cancel 2 bits'
    expect(leaves[0, 4].reduce(:^) >> 4).not_to eq(0), 'the height-2 node must NOT cancel 4 bits'

    expect(verify_counting((0...8).to_a, params: described_class.params(n: 8, k: 3), salt:)).to eq([false, 4])
  end
end

# Python parity: these examples need python3 (and numpy for solve.py).
module EquihashParity
  SOLVER = File.expand_path('../../../solve.py', __dir__)
  PYTHONS = %w[python3.14 python3.13 python3.12 python3 /opt/homebrew/bin/python3].freeze

  # Skips when the toolchain is absent, unless the environment undertook to
  # provide it: a skip reads as a pass in every CI summary line.
  def parity_skip(reason)
    if ENV['KIOSK_REQUIRE_PARITY'] == '1'
      raise 'KIOSK_REQUIRE_PARITY=1 was set, so the caller undertook to provide the parity ' \
            "toolchain — #{reason}. Do NOT relax this to a skip: these examples are the only " \
            'cross-implementation check of the shipped solver, and a skipped example reads as ' \
            'a passing one.'
    end

    skip reason
  end

  def python_with(imports)
    PYTHONS.find do |py|
      system("#{py} -c 'import #{imports}; hashlib.blake2b(b\"\", digest_size=32)' 2>/dev/null")
    end
  end

  # solve.py's answer for `salt` at `params`, or a skip when it cannot run.
  def python_solve(salt, params)
    skip 'solve.py not found' unless File.exist?(SOLVER)
    python = python_with('hashlib, numpy')
    parity_skip('python3 with numpy not found (pip install numpy)') unless python

    require 'base64'
    challenge = JSON.generate('salt_b64' => Base64.strict_encode64(salt), 'params' => params, 'header_nonce' => 0)
    result = JSON.parse(`#{python} #{SOLVER.shellescape} #{challenge.shellescape}`.strip)
    skip "Python solver failed: #{result['error']}" if result.key?('error')
    result['indices']
  end
end

RSpec.describe Kiosk::Pow::Equihash, 'Python solver parity', :parity do
  include EquihashParity

  it 'Python blake2b matches Ruby for the KAT seed' do
    python = python_with('hashlib')
    parity_skip('python3 with hashlib.blake2b not found') unless python
    script = 'import hashlib, struct; ' \
             'print(hashlib.blake2b(b"kat" + struct.pack("<I", 0) + struct.pack("<Q", 2), digest_size=32).hexdigest())'
    py_hex = IO.popen([python, '-c', script], &:read).strip

    expect(py_hex).to eq(Kiosk::Pow::Blake2b.digest256("kat\0\0\0\0#{[2].pack('Q<')}".b).unpack1('H*'))
  end

  it 'Ruby verify accepts a toy (n=8,k=1) proof from Python solver' do
    indices = python_solve('kat'.b, { 'n' => 8, 'k' => 1 })
    ok = described_class.verify(salt: 'kat'.b, params: described_class.params(n: 8, k: 1), nonce: { 'indices' => indices })
    expect(ok).to be(true), "Ruby verify rejected Python output: #{indices.inspect}"
  end

  # The frozen KAT is the only other check at the shipped 168/7; this one
  # live-solves there. About 10 s to solve.
  it 'Ruby verify accepts a LIVE production-param (n=168,k=7) proof from the Python solver' do
    salt    = 'kiosk-eqx-parity-168'.b
    indices = python_solve(salt, { 'n' => 168, 'k' => 7 })
    ok = described_class.verify(salt:, params: described_class.params(n: 168, k: 7), nonce: { 'indices' => indices })
    expect(ok).to be(true), "Ruby verify rejected the solver's live 168/7 output: #{indices.inspect}"
  end
end
