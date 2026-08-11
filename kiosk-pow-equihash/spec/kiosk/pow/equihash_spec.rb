# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe Kiosk::Pow::Equihash do
  # ─────────────────────────────────────────────────────────────────────
  # NAME / .params
  # ─────────────────────────────────────────────────────────────────────

  describe "NAME" do
    it "is 'equihash'" do
      expect(described_class::NAME).to eq("equihash")
    end
  end

  describe "DEFAULT_N / DEFAULT_K" do
    it "are the benchmark-chosen defaults (168, 7)" do
      expect(described_class::DEFAULT_N).to eq(168)
      expect(described_class::DEFAULT_K).to eq(7)
    end
  end

  describe ".params" do
    it "returns n:168, k:7 by default" do
      p = described_class.params
      expect(p).to eq({ n: 168, k: 7 })
    end

    it "accepts custom n and k" do
      p = described_class.params(n: 200, k: 9)
      expect(p).to eq({ n: 200, k: 9 })
    end
  end

  describe ".solver_path" do
    # The accessor is the PUBLIC contract consumers (kiosk-redteam's client
    # first) shell out to instead of reaching into this gem's directory by a
    # checkout-relative path — so it must name a file that actually exists,
    # inside this gem's own root, wherever the gem is installed.
    it "returns the absolute path of an existing solve.py inside the gem root" do
      path = described_class.solver_path

      expect(path).to eq(File.expand_path(path))                      # absolute
      expect(File.basename(path)).to eq("solve.py")
      expect(File.file?(path)).to be(true)

      gem_root = File.expand_path("../../..", __dir__)                # spec/kiosk/pow → gem dir
      expect(path).to eq(File.join(gem_root, "solve.py"))
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # .blake2b256 — known-answer vectors cross-referenced with Python hashlib
  #
  #   hashlib.blake2b(b"", digest_size=32).hexdigest()
  #   => "0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8"
  #
  #   hashlib.blake2b(b"hello", digest_size=32).hexdigest()
  #   => "324dcf027dd4a30a932c441f365a25e86b173defa4b8e58948253471b81b72cf"
  # ─────────────────────────────────────────────────────────────────────

  describe ".blake2b256" do
    it "matches Python hashlib for empty input" do
      result = described_class.blake2b256("".b)
      expect(result.unpack1("H*")).to eq(
        "0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8"
      )
    end

    it "matches Python hashlib for 'hello'" do
      result = described_class.blake2b256("hello")
      expect(result.unpack1("H*")).to eq(
        "324dcf027dd4a30a932c441f365a25e86b173defa4b8e58948253471b81b72cf"
      )
    end

    it "returns 32 bytes" do
      expect(described_class.blake2b256("x").bytesize).to eq(32)
    end

    it "is deterministic" do
      expect(described_class.blake2b256("abc")).to eq(described_class.blake2b256("abc"))
    end

    it "changes with input" do
      expect(described_class.blake2b256("a")).not_to eq(described_class.blake2b256("b"))
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # .verify — hand-constructed KAT for (n=8, k=1)
  #
  # n=8, k=1 → n_div=4, proofsize=2.
  # Seed: "kat" + LE32(0) = 6b 61 74 00 00 00 00
  # Brute-force: find pair with XOR=0 in first byte.
  #
  # Verified against Python blake2b:
  #   hashlib.blake2b(b"kat\x00\x00\x00\x00" + struct.pack("<Q", 2))[0]  = 0x9e
  #   hashlib.blake2b(b"kat\x00\x00\x00\x00" + struct.pack("<Q", 10))[0] = 0x9e
  #   → XOR = 0 in first byte ✓
  # ─────────────────────────────────────────────────────────────────────

  let(:kat_salt)    { "kat".b }
  let(:kat_params)  { described_class.params(n: 8, k: 1) }
  let(:kat_proof)   { { indices: [2, 10] } }

  it "KAT: the constructed pair XORs to zero" do
    seed = kat_salt + [0].pack("V")
    h2  = described_class.blake2b256(seed + [2].pack("Q<"))
    h10 = described_class.blake2b256(seed + [10].pack("Q<"))
    xor_byte = h2.bytes.first ^ h10.bytes.first
    expect(xor_byte).to eq(0), "KAT construction is wrong"
  end

  describe ".verify" do
    it "ACCEPT — valid KAT (n=8,k=1, indices [2,10])" do
      expect(described_class.verify(salt: kat_salt, params: kat_params, nonce: kat_proof)).to be(true)
    end

    it "ACCEPT — valid KAT with string keys in nonce" do
      expect(described_class.verify(
        salt: kat_salt, params: kat_params, nonce: { "indices" => [2, 10] }
      )).to be(true)
    end

    it "ACCEPT — valid KAT with string keys in params" do
      expect(described_class.verify(
        salt: kat_salt, params: { "n" => 8, "k" => 1 }, nonce: kat_proof
      )).to be(true)
    end

    # ─── Multi-level KATs (k ≥ 2) — the real Wagner tree ─────────────────
    #
    # Deterministic solutions from the reference Wagner solver, salt
    # "kiosk-eqx-kat-01" (16 bytes), header_nonce 0. Indices are in Zcash
    # CANONICAL (subtree) order — NOT globally sorted: at each tree node the
    # left half's first index precedes the right half's. A genuine Wagner
    # solution cancels each level's block via XOR (the leaves do NOT share a
    # prefix), and its canonical order is not ascending — the two properties
    # the pre-fix verifier got wrong (it demanded leaf-prefix equality + a
    # global sort, which no real k≥2 solution satisfies).
    let(:m_salt) { "kiosk-eqx-kat-01".b }

    it "ACCEPT — valid k=2 KAT (n=24, canonical/tree order)" do
      expect(described_class.verify(
        salt: m_salt, params: described_class.params(n: 24, k: 2),
        nonce: { indices: [29, 653, 113, 572] },
      )).to be(true)
    end

    it "ACCEPT — valid k=3 KAT (n=32, canonical/tree order)" do
      expect(described_class.verify(
        salt: m_salt, params: described_class.params(n: 32, k: 3),
        nonce: { indices: [31, 833, 279, 285, 147, 676, 596, 738] },
      )).to be(true)
    end

    it "REJECT — the SAME k=2 solution globally sorted (breaks the tree pairing)" do
      # Sorting regroups (29,653)(113,572) into (29,113)(572,653), which are
      # not the colliding pairs → the level-0 XOR no longer cancels.
      expect(described_class.verify(
        salt: m_salt, params: described_class.params(n: 24, k: 2),
        nonce: { indices: [29, 113, 572, 653] },
      )).to be(false)
    end

    it "REJECT — k=2 with one mutated index (XOR no longer cancels)" do
      expect(described_class.verify(
        salt: m_salt, params: described_class.params(n: 24, k: 2),
        nonce: { indices: [29, 653, 113, 573] },
      )).to be(false)
    end

    it "REJECT — k=2 canonical values but subtree order violated (halves swapped)" do
      # Swap the two level-1 halves: right subtree (113,572) placed before the
      # left (29,653). XOR still cancels, but left.first(113) > right.first(29)
      # violates the canonical subtree ordering.
      expect(described_class.verify(
        salt: m_salt, params: described_class.params(n: 24, k: 2),
        nonce: { indices: [113, 572, 29, 653] },
      )).to be(false)
    end

    # ─── REJECT — hash mismatch ──────────────────────────────────────

    it "REJECT — wrong salt" do
      expect(described_class.verify(salt: "bad".b, params: kat_params, nonce: kat_proof)).to be(false)
    end

    it "REJECT — mutated index (2→3)" do
      expect(described_class.verify(
        salt: kat_salt, params: kat_params, nonce: { indices: [3, 10] }
      )).to be(false)
    end

    # ─── REJECT — structural violations ──────────────────────────────

    it "REJECT — wrong count (3 indices, k=1 expects 2)" do
      expect(described_class.verify(
        salt: kat_salt, params: kat_params, nonce: { indices: [2, 10, 42] }
      )).to be(false)
    end

    it "REJECT — too few indices" do
      expect(described_class.verify(
        salt: kat_salt, params: kat_params, nonce: { indices: [2] }
      )).to be(false)
    end

    it "REJECT — empty indices" do
      expect(described_class.verify(
        salt: kat_salt, params: kat_params, nonce: { indices: [] }
      )).to be(false)
    end

    it "REJECT — non-ascending [10, 2]" do
      expect(described_class.verify(
        salt: kat_salt, params: kat_params, nonce: { indices: [10, 2] }
      )).to be(false)
    end

    it "REJECT — duplicate [2, 2]" do
      expect(described_class.verify(
        salt: kat_salt, params: kat_params, nonce: { indices: [2, 2] }
      )).to be(false)
    end

    it "REJECT — float in indices" do
      expect(described_class.verify(
        salt: kat_salt, params: kat_params, nonce: { indices: [2.0, 10] }
      )).to be(false)
    end

    # A malformed index (nil / non-numeric string) must return false,
    # never raise. Guards the `indices.all? { Integer && >= 0 }` check that
    # replaced a coercing `Integer(idx)` (which raised TypeError/ArgumentError).
    it "REJECT — nil element in indices (returns false, does not raise)" do
      expect(described_class.verify(
        salt: kat_salt, params: kat_params, nonce: { indices: [nil, 10] }
      )).to be(false)
    end

    it "REJECT — non-numeric string element in indices (returns false, does not raise)" do
      expect(described_class.verify(
        salt: kat_salt, params: kat_params, nonce: { indices: ["x", 10] }
      )).to be(false)
    end

    # ─── REJECT — guard rails ────────────────────────────────────────

    it "REJECT — nonce is nil" do
      expect(described_class.verify(salt: kat_salt, params: kat_params, nonce: nil)).to be(false)
    end

    it "REJECT — nonce is not a Hash" do
      expect(described_class.verify(salt: kat_salt, params: kat_params, nonce: "bad")).to be(false)
    end

    it "REJECT — nonce missing :indices" do
      expect(described_class.verify(salt: kat_salt, params: kat_params, nonce: {})).to be(false)
    end

    it "REJECT — :indices is not an Array" do
      expect(described_class.verify(
        salt: kat_salt, params: kat_params, nonce: { indices: "nope" }
      )).to be(false)
    end

    # ─── header_nonce ────────────────────────────────────────────────

    it "REJECT — different header_nonce changes seed" do
      expect(described_class.verify(
        salt: kat_salt, params: kat_params, nonce: { indices: [2, 10], header_nonce: 1 }
      )).to be(false)
    end

    # header_nonce is client-supplied and flowed straight
    # into `Integer(hn)` — a non-numeric value raised ArgumentError/TypeError
    # (an HTTP 500 at the wire), violating the "return false, never raise"
    # contract the index guard above already honours.
    it "REJECT — non-numeric string header_nonce (returns false, does not raise)" do
      expect(described_class.verify(
        salt: kat_salt, params: kat_params,
        nonce: { "indices" => [2, 10], "header_nonce" => "abc" }
      )).to be(false)
    end

    it "REJECT — non-coercible header_nonce type (Array) returns false, does not raise" do
      expect(described_class.verify(
        salt: kat_salt, params: kat_params,
        nonce: { indices: [2, 10], header_nonce: [1] }
      )).to be(false)
    end

    it "REJECT — Hash header_nonce returns false, does not raise" do
      expect(described_class.verify(
        salt: kat_salt, params: kat_params,
        nonce: { indices: [2, 10], header_nonce: { "x" => 1 } }
      )).to be(false)
    end

    it "ACCEPT — header_nonce=0 same as default" do
      expect(described_class.verify(
        salt: kat_salt, params: kat_params, nonce: { indices: [2, 10], header_nonce: 0 }
      )).to be(true)
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # (n=8, k=2) — hand-computed KAT
  #
  # n=8, k=2 → n_div=2, proofsize=4.
  # Seed: "kat" + LE32(0) = 6b 61 74 00 00 00 00
  # Brute-force: 4 distinct indices with valid collision tree and XOR=0.
  #
  # Verified against Python blake2b:
  #   hash("kat\x00\x00\x00\x00" + LE64( 0))[0] = 0xbf
  #   hash("kat\x00\x00\x00\x00" + LE64( 5))[0] = 0xba
  #   hash("kat\x00\x00\x00\x00" + LE64(33))[0] = 0xbc
  #   hash("kat\x00\x00\x00\x00" + LE64(84))[0] = 0xb9
  #   → top 2 bits all 0b10, top 4 all 0b1011, XOR = 0xbf^0xba^0xbc^0xb9 = 0 ✓
  # ─────────────────────────────────────────────────────────────────────

  let(:kat8x2_salt)   { "kat".b }
  let(:kat8x2_params) { described_class.params(n: 8, k: 2) }
  let(:kat8x2_proof)  { { indices: [0, 5, 33, 84] } }

  it "KAT (8,2): indices XOR to zero and form a valid collision tree" do
    seed = kat8x2_salt + [0].pack("V")
    h0  = described_class.blake2b256(seed + [0].pack("Q<"))
    h5  = described_class.blake2b256(seed + [5].pack("Q<"))
    h33 = described_class.blake2b256(seed + [33].pack("Q<"))
    h84 = described_class.blake2b256(seed + [84].pack("Q<"))
    xor_byte = h0.bytes[0] ^ h5.bytes[0] ^ h33.bytes[0] ^ h84.bytes[0]
    expect(xor_byte).to eq(0), "KAT (8,2) XOR is wrong"
  end

  it "ACCEPT — valid KAT (n=8,k=2, indices [0,5,33,84])" do
    expect(described_class.verify(
      salt: kat8x2_salt, params: kat8x2_params, nonce: kat8x2_proof
    )).to be(true)
  end

  # ─────────────────────────────────────────────────────────────────────
  # Production-parameter KAT (n=168, k=7) — frozen reference solution
  #
  # Generated 2026-07-09 by the reference solver (solve.py, numpy):
  #   salt "kiosk-eqx-kat-01", params {n: 168, k: 7}, header_nonce 0
  # Indices in Zcash-canonical (subtree) order. Pins the verifier at the
  # shipped default parameters, not just toy sizes.
  # ─────────────────────────────────────────────────────────────────────

  describe "production params (n=168, k=7) KAT" do
    let(:prod_salt) { "kiosk-eqx-kat-01".b }
    let(:prod_params) { described_class.params(n: 168, k: 7) }
    let(:prod_indices) do
      [
        35635, 443602, 769922, 2841204, 288650, 2534367, 3711384, 4167287,
        439322, 3579870, 3884016, 4011474, 1469807, 2859441, 1582951, 2663283,
        175258, 904564, 2551933, 3478559, 2097074, 2914645, 3026485, 3645933,
        326539, 3134338, 1410867, 3946408, 1215314, 2610863, 1729482, 2563633,
        215557, 1365296, 3286033, 3379331, 1092666, 2048436, 1956659, 4083619,
        327630, 966319, 546923, 3597822, 1019737, 3289324, 2515996, 4102785,
        352766, 2643465, 2237387, 3118040, 1365775, 3292860, 1484813, 2325158,
        1130131, 3785225, 1311199, 1689016, 1154546, 2027634, 2238579, 2294173,
        47664, 1747214, 1924004, 2999276, 2036646, 2481260, 2187884, 3492692,
        1006856, 1260610, 1570131, 3646554, 1388645, 2876691, 2128978, 2588422,
        367435, 513091, 3105269, 4005382, 489985, 629292, 2672040, 2928191,
        367906, 2335214, 761171, 3386820, 681939, 2064865, 1410874, 1730962,
        219306, 4024412, 1712945, 3300801, 719958, 3009238, 1383878, 2994505,
        417321, 3362644, 2678745, 2792851, 2071420, 2778845, 2441747, 4028940,
        220716, 2282797, 1287422, 1739283, 1064154, 3198198, 3579075, 3590378,
        228235, 2335503, 1297479, 3907179, 1108349, 2972099, 3417182, 3877732
      ]
    end

    it "ACCEPT — the frozen reference solution (canonical order)" do
      expect(described_class.verify(
        salt: prod_salt, params: prod_params, nonce: { indices: prod_indices }
      )).to be(true)
    end

    it "REJECT — the same solution globally sorted (breaks tree pairing)" do
      expect(described_class.verify(
        salt: prod_salt, params: prod_params, nonce: { indices: prod_indices.sort }
      )).to be(false)
    end

    it "REJECT — one mutated index (XOR no longer cancels)" do
      mutated = prod_indices.dup.tap { |ix| ix[127] += 1 }
      expect(described_class.verify(
        salt: prod_salt, params: prod_params, nonce: { indices: mutated }
      )).to be(false)
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # default params (n=168, k=7) structural checks
  # ─────────────────────────────────────────────────────────────────────

  describe "default params (n=168, k=7)" do
    let(:big_params) { described_class.params }

    it "REJECT — 127 indices (expect 128)" do
      expect(described_class.verify(
        salt: "x".b, params: big_params, nonce: { indices: (0...127).to_a }
      )).to be(false)
    end

    it "REJECT — 129 indices (expect 128)" do
      expect(described_class.verify(
        salt: "x".b, params: big_params, nonce: { indices: (0...129).to_a }
      )).to be(false)
    end

    it "REJECT — non-ascending (first two swapped)" do
      indices = (0...128).to_a
      indices[0], indices[1] = indices[1], indices[0]
      expect(described_class.verify(
        salt: "x".b, params: big_params, nonce: { indices: indices }
      )).to be(false)
    end

    it "REJECT — duplicate at end" do
      indices = (0...128).to_a
      indices[127] = indices[126]
      expect(described_class.verify(
        salt: "x".b, params: big_params, nonce: { indices: indices }
      )).to be(false)
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # Python solver cross-implementation parity
  # ─────────────────────────────────────────────────────────────────────

  describe "Python solver parity", :parity do
    let(:python) { find_python_with_blake2b }

    before { skip "python3 with hashlib.blake2b not found" unless python }

    it "Python blake2b matches Ruby for the KAT seed" do
      require "tempfile"
      py_script = <<~PY
        import hashlib, struct
        seed = b"kat" + struct.pack("<I", 0)
        h = hashlib.blake2b(seed + struct.pack("<Q", 2), digest_size=32).digest()
        print(h.hex())
      PY
      py_hex = Tempfile.open(["kiosk_eq", ".py"]) { |f| f.write(py_script); f.flush; `#{python} #{f.path.shellescape}`.strip }

      seed = "kat".b + [0].pack("V")
      ruby_hex = described_class.blake2b256(seed + [2].pack("Q<")).unpack1("H*")
      expect(py_hex).to eq(ruby_hex)
    end

    it "Ruby verify accepts a toy (n=8,k=1) proof from Python solver" do
      solver_py = File.join(__dir__, "../../../solve.py")
      skip "solve.py not found" unless File.exist?(solver_py)

      # solve.py requires numpy; the plain blake2b python may lack it.
      python = find_python_with_numpy
      skip "python3 with numpy not found (pip install numpy)" unless python

      require "base64"
      challenge = JSON.generate(
        "salt_b64" => Base64.strict_encode64("kat".b),
        "params"   => { "n" => 8, "k" => 1 },
        "header_nonce" => 0,
      )
      out    = `#{python} #{solver_py.shellescape} #{challenge.shellescape}`.strip
      result = JSON.parse(out)

      if result.key?("error")
        skip "Python solver failed: #{result["error"]}"
      end

      ok = described_class.verify(
        salt: "kat".b, params: described_class.params(n: 8, k: 1),
        nonce: { "indices" => result["indices"] },
      )
      expect(ok).to be(true), "Ruby verify rejected Python output: #{result["indices"].inspect}"
    end

    # T-013: the toy roundtrip above proves the wire, but the shipped params are
    # n=168 k=7. Only the frozen KAT exercises the verifier at 168/7; nothing
    # LIVE-solves there. This closes that gap end-to-end: solve.py produces a
    # fresh 168/7 proof and the Ruby verifier must accept it — the "KATs must run
    # at shipped params" lesson from the verifier-bug incident. ~9-10 s to solve.
    it "Ruby verify accepts a LIVE production-param (n=168,k=7) proof from the Python solver" do
      solver_py = File.join(__dir__, "../../../solve.py")
      skip "solve.py not found" unless File.exist?(solver_py)

      python = find_python_with_numpy
      skip "python3 with numpy not found (pip install numpy)" unless python

      require "base64"
      salt      = "kiosk-eqx-parity-168".b
      challenge = JSON.generate(
        "salt_b64"     => Base64.strict_encode64(salt),
        "params"       => { "n" => 168, "k" => 7 },
        "header_nonce" => 0,
      )
      out    = `#{python} #{solver_py.shellescape} #{challenge.shellescape}`.strip
      result = JSON.parse(out)
      skip "Python solver failed: #{result["error"]}" if result.key?("error")

      ok = described_class.verify(
        salt: salt, params: described_class.params(n: 168, k: 7),
        nonce: { "indices" => result["indices"] },
      )
      expect(ok).to be(true),
        "Ruby verify rejected the solver's live 168/7 output: #{result["indices"].inspect}"
    end
  end

  def find_python_with_blake2b
    %w[python3.14 python3.13 python3.12 python3 /opt/homebrew/bin/python3].find { |py|
      system("#{py} -c 'import hashlib; hashlib.blake2b(b\"\", digest_size=32)' 2>/dev/null")
    }
  end

  # solve.py needs numpy (the Wagner sort/collide steps are vectorised), so its
  # parity test must pick an interpreter that has it, not just blake2b.
  def find_python_with_numpy
    %w[python3.14 python3.13 python3.12 python3 /opt/homebrew/bin/python3].find { |py|
      system("#{py} -c 'import hashlib, numpy; hashlib.blake2b(b\"\", digest_size=32)' 2>/dev/null")
    }
  end
end
