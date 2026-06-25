# frozen_string_literal: true

require "spec_helper"
require "json"
require "shellwords"

RSpec.describe Kiosk::Pow do
  # ---------------------------------------------------------------------------
  # Constants
  # ---------------------------------------------------------------------------

  describe "NAME" do
    it "is 'argon2id'" do
      expect(described_class::NAME).to eq("argon2id")
    end
  end

  # ---------------------------------------------------------------------------
  # .params
  # ---------------------------------------------------------------------------

  describe ".params" do
    it "returns a hash with all four keys" do
      result = described_class.params(d: 6)
      expect(result).to include(m: 65_536, t: 1, p: 1, d: 6)
    end

    it "accepts custom m, t, p" do
      result = described_class.params(d: 8, m: 8_192, t: 2, p: 2)
      expect(result).to eq({ m: 8_192, t: 2, p: 2, d: 8 })
    end

    it "d: 0 is a valid (no-challenge) difficulty" do
      result = described_class.params(d: 0)
      expect(result[:d]).to eq(0)
    end
  end

  # ---------------------------------------------------------------------------
  # .leading_zero_bits
  # ---------------------------------------------------------------------------

  describe ".leading_zero_bits" do
    it "returns 0 for an empty string" do
      expect(described_class.leading_zero_bits("")).to eq(0)
    end

    it "counts 0 leading zeros for 0x80 (MSB set)" do
      expect(described_class.leading_zero_bits("\x80")).to eq(0)
    end

    it "counts 1 leading zero for 0x40" do
      expect(described_class.leading_zero_bits("\x40")).to eq(1)
    end

    it "counts 6 leading zeros for 0x02" do
      expect(described_class.leading_zero_bits("\x02")).to eq(6)
    end

    it "counts 7 leading zeros for 0x01" do
      expect(described_class.leading_zero_bits("\x01")).to eq(7)
    end

    it "counts 8 leading zeros for a zero byte and stops at the next non-zero byte" do
      # 0x00 0x80 → 8 + 0 = 8
      expect(described_class.leading_zero_bits("\x00\x80")).to eq(8)
    end

    it "spans across multiple zero bytes" do
      # 0x00 0x00 0x40 → 8 + 8 + 1 = 17
      expect(described_class.leading_zero_bits("\x00\x00\x40")).to eq(17)
    end

    it "returns 8 * byte_count for an all-zero input" do
      expect(described_class.leading_zero_bits("\x00\x00\x00\x00")).to eq(32)
    end

    it "ignores bytes after the first non-zero byte" do
      # 0x40 0x00 → 1 (zero bytes after the non-zero byte don't add to count)
      expect(described_class.leading_zero_bits("\x40\x00")).to eq(1)
    end
  end

  # ---------------------------------------------------------------------------
  # .digest — known-answer / determinism vector
  #
  # CANONICAL VECTOR (record this; update only if the Argon2id params change):
  #   salt    = "testsalt12345678"  (16 raw ASCII bytes)
  #   nonce   = "42"               (decimal ASCII string)
  #   m       = 8_192 KiB
  #   t       = 1
  #   p       = 1
  #   version = 0x13 (19)
  #   → digest (hex) = 020b766a76b5149e772a60e06b0c26975b07fc6073fa107650bdeab15cb95118
  #   → leading_zero_bits = 6
  #
  # Cross-impl parity (Python argon2-cffi with the same inputs):
  #   argon2.low_level.hash_secret_raw(secret=b"42", salt=b"testsalt12345678",
  #     time_cost=1, memory_cost=8192, parallelism=1, hash_len=32,
  #     type=Type.ID, version=19)
  #   → b"\x02\x0bvjv\xb5\x14\x9ew*`\xe0k\x0c&\x97[\x07\xfc`s\xfa\x10v..."
  #   → hex = 020b766a76b5149e772a60e06b0c26975b07fc6073fa107650bdeab15cb95118
  # (confirmed identical — see `bundle exec rake parity`)
  # ---------------------------------------------------------------------------

  describe ".digest" do
    let(:salt)   { "testsalt12345678" }
    let(:params) { described_class.params(d: 6, m: 8_192, t: 1, p: 1) }

    it "returns 32 raw bytes" do
      result = described_class.digest(salt:, params:, nonce: "42")
      expect(result.bytesize).to eq(32)
    end

    it "is deterministic (known-answer vector)" do
      result = described_class.digest(salt:, params:, nonce: "42")
      expect(result.unpack1("H*")).to eq(
        "020b766a76b5149e772a60e06b0c26975b07fc6073fa107650bdeab15cb95118"
      )
    end

    it "accepts an integer nonce (converts to decimal string)" do
      result_int = described_class.digest(salt:, params:, nonce: 42)
      result_str = described_class.digest(salt:, params:, nonce: "42")
      expect(result_int).to eq(result_str)
    end

    it "changes with a different nonce" do
      d1 = described_class.digest(salt:, params:, nonce: "42")
      d2 = described_class.digest(salt:, params:, nonce: "43")
      expect(d1).not_to eq(d2)
    end

    it "changes with a different salt" do
      d1 = described_class.digest(salt: "testsalt12345678", params:, nonce: "42")
      d2 = described_class.digest(salt: "differentsalt678", params:, nonce: "42")
      expect(d1).not_to eq(d2)
    end
  end

  # ---------------------------------------------------------------------------
  # .verify
  # ---------------------------------------------------------------------------

  describe ".verify" do
    let(:salt)   { "testsalt12345678" }

    # Known-good: nonce "42" → 6 leading zero bits with m=8_192
    it "returns true when the nonce satisfies d" do
      params = described_class.params(d: 6, m: 8_192, t: 1, p: 1)
      expect(described_class.verify(salt:, params:, nonce: "42")).to be(true)
    end

    it "returns false when d exceeds the actual leading zero bits" do
      params = described_class.params(d: 7, m: 8_192, t: 1, p: 1)
      expect(described_class.verify(salt:, params:, nonce: "42")).to be(false)
    end

    it "returns true for d: 0 (any nonce is valid)" do
      params = described_class.params(d: 0, m: 8_192, t: 1, p: 1)
      expect(described_class.verify(salt:, params:, nonce: "999")).to be(true)
    end

    it "returns false for a wrong nonce with realistic d" do
      # nonce "1" has a different digest; we check it against d=6
      params = described_class.params(d: 6, m: 8_192, t: 1, p: 1)
      # The known-good nonce is "42"; a random other nonce is almost certainly wrong
      d1  = described_class.digest(salt:, params:, nonce: "1")
      lzb = described_class.leading_zero_bits(d1)
      # Only run this assertion when the nonce genuinely fails (expected probability ~99%)
      if lzb < 6
        expect(described_class.verify(salt:, params:, nonce: "1")).to be(false)
      else
        # In the astronomically unlikely case nonce "1" also has ≥6 LZB, skip.
        skip "nonce '1' happens to also satisfy d=6 (lzb=#{lzb})"
      end
    end

    it "computes exactly one digest (no iteration)" do
      params = described_class.params(d: 6, m: 8_192, t: 1, p: 1)
      call_count = 0
      allow(described_class).to receive(:digest).and_wrap_original do |m, **kwargs|
        call_count += 1
        m.call(**kwargs)
      end
      described_class.verify(salt:, params:, nonce: "42")
      expect(call_count).to eq(1)
    end
  end

  # ---------------------------------------------------------------------------
  # Cross-implementation parity (shells out to Python)
  #
  # Skipped automatically if no python3 with argon2-cffi is available.
  # Run `bundle exec rake parity` for the full interactive parity report.
  # ---------------------------------------------------------------------------

  describe "Python solver cross-implementation parity", :parity do
    let(:salt)        { "testsalt12345678" }
    let(:python)      { find_python_with_argon2 }
    let(:solve_py)    { File.join(__dir__, "../../solve.py") }

    before { skip "python3 with argon2-cffi not found" unless python }

    it "Python argon2-cffi produces the same digest as Ruby for the known vector" do
      require "tempfile"

      py_script = <<~PY
        import argon2.low_level, sys
        d = argon2.low_level.hash_secret_raw(
            secret=b"42", salt=b"testsalt12345678",
            time_cost=1, memory_cost=8192, parallelism=1,
            hash_len=32, type=argon2.low_level.Type.ID, version=19)
        sys.stdout.write(d.hex())
      PY

      python_hex = Tempfile.open(["kiosk_pow_parity", ".py"], binmode: false) do |f|
        f.write(py_script)
        f.flush
        `#{python} #{f.path.shellescape}`.strip
      end

      ruby_hex = described_class.digest(
        salt:, params: described_class.params(d: 6, m: 8_192, t: 1, p: 1), nonce: "42"
      ).unpack1("H*")

      expect(python_hex).to eq(ruby_hex),
        "Digest mismatch!\n  Ruby:   #{ruby_hex}\n  Python: #{python_hex}"
    end

    it "Ruby verify accepts a nonce produced by solve.py (end-to-end parity)" do
      skip "solve.py not found" unless File.exist?(solve_py)

      challenge_json = JSON.generate(
        "salt"   => [salt].pack("m0"),
        "params" => { "m" => 8_192, "t" => 1, "p" => 1, "d" => 8 }
      )
      solve_out   = `#{python} #{solve_py.shellescape} #{challenge_json.shellescape}`.strip
      result      = JSON.parse(solve_out)
      found_nonce = result.fetch("nonce")

      params = described_class.params(d: 8, m: 8_192, t: 1, p: 1)
      expect(described_class.verify(salt:, params:, nonce: found_nonce)).to be(true),
        "Ruby verify rejected solve.py nonce #{found_nonce.inspect}"
    end

    def find_python_with_argon2
      %w[
        /opt/homebrew/bin/python3
        python3.14
        python3.13
        python3.12
        python3
      ].find { |py| system("#{py} -c 'import argon2.low_level' 2>/dev/null") }
    end
  end
end
