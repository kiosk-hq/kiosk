# frozen_string_literal: true

require 'json'
require 'shellwords'
require 'tempfile'

# Runs the Python side of the Argon2id parity examples.
module PythonParity
  CANDIDATES = %w[
    /opt/homebrew/bin/python3
    python3.14
    python3.13
    python3.12
    python3
  ].freeze

  DIGEST_SCRIPT = <<~PY
    import argon2.low_level, sys
    d = argon2.low_level.hash_secret_raw(
        secret=b"42", salt=b"testsalt12345678",
        time_cost=1, memory_cost=8192, parallelism=1,
        hash_len=32, type=argon2.low_level.Type.ID, version=19)
    sys.stdout.write(d.hex())
  PY

  def find_python_with_argon2
    CANDIDATES.find { |py| system("#{py} -c 'import argon2.low_level' 2>/dev/null") }
  end

  # Fails when KIOSK_REQUIRE_PARITY=1 promised the interpreter, else skips.
  # A skipped example reads as a passing one, and nothing else compares the
  # packaged solve.py with this verifier.
  def require_python!
    if ENV['KIOSK_REQUIRE_PARITY'] == '1'
      raise 'KIOSK_REQUIRE_PARITY=1 was set, so the caller undertook to provide a python3 ' \
            'with argon2-cffi — and none of the candidate interpreters has it. Do NOT relax ' \
            'this to a skip: nothing else checks that the packaged solve.py and this verifier ' \
            'agree, and a skipped example reads as a passing one.'
    end

    skip 'python3 with argon2-cffi not found'
  end

  def python_digest_hex
    Tempfile.open(['kiosk_pow_parity', '.py'], binmode: false) do |f|
      f.write(DIGEST_SCRIPT)
      f.flush
      `#{python} #{f.path.shellescape}`.strip
    end
  end

  def solve_py_nonce(params)
    challenge_json = JSON.generate('salt' => [salt].pack('m0'), 'params' => params)
    solve_out = `#{python} #{solve_py.shellescape} #{challenge_json.shellescape}`.strip
    JSON.parse(solve_out).fetch('nonce')
  end
end
