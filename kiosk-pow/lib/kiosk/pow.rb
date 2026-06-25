# frozen_string_literal: true

require "ffi"
require "argon2"

require "kiosk/pow/version"

module Kiosk
  # Argon2id memory-hard proof-of-work backend for Kiosk.
  #
  # Provider-side Ruby verify + the shipped Python solver (solve.py).
  # The wire protocol is algorithm-agnostic; kiosk-reputation dispatches here
  # when {NAME} is the demanded algorithm.
  #
  # == Canonical PoW computation (byte-identical in Ruby verify and Python solve)
  #
  # Primitive: raw Argon2id (libargon2), type = Argon2id, version = 0x13 (19),
  # hash_len = 32 bytes.
  #
  #   Argon2id(password: nonce.to_s,   # decimal ASCII string encoded as UTF-8
  #            salt:     raw_salt_bytes, # ≥ 8 raw bytes; wire base64 decoded upstream
  #            m_cost:   params[:m],     # memory in KiB
  #            t_cost:   params[:t],     # iterations
  #            parallelism: params[:p],  # 1
  #            version:  0x13, hash_len: 32)
  #
  # A nonce is a valid solution iff leading_zero_bits(digest) >= params[:d].
  module Pow
    # Algorithm name advertised in the challenge.
    NAME = "argon2id"

    # Build the algorithm-specific challenge params for a difficulty tier.
    #
    # @param d [Integer] required leading zero bits (0 = no challenge)
    # @param m [Integer] memory in KiB (default 64 MiB = 65_536 KiB)
    # @param t [Integer] iterations (default 1)
    # @param p [Integer] parallelism (default 1; the Python solver also uses p=1)
    # @return [Hash{m: Integer, t: Integer, p: Integer, d: Integer}]
    def self.params(d:, m: 65_536, t: 1, p: 1)
      { m:, t:, p:, d: }
    end

    # One raw Argon2id evaluation — 32 raw bytes.
    #
    # Uses {Argon2::Ext.argon2id_hash_raw} directly (bypasses the Password
    # high-level API which converts m_cost to a power-of-two exponent).
    # libargon2's `argon2id_hash_raw` always uses version 0x13 (ARGON2_VERSION_13),
    # which is identical to argon2-cffi's `version=19` — byte-identical output
    # is verified by the `parity` Rake task.
    #
    # @param salt   [String] raw bytes (≥ 8 bytes); decoding from base64 happens upstream
    # @param params [Hash]   as returned by {.params}
    # @param nonce  [#to_s] the nonce (converted to decimal ASCII string, e.g. "0", "1234")
    # @return [String] 32 raw bytes (binary encoding)
    def self.digest(salt:, params:, nonce:)
      password = nonce.to_s.encode(Encoding::ASCII)
      m = Integer(params[:m])
      t = Integer(params[:t])
      p = Integer(params[:p])

      result = nil
      FFI::MemoryPointer.new(:char, 32) do |buffer|
        ret = Argon2::Ext.argon2id_hash_raw(
          t, m, p,
          password, password.bytesize,
          salt,     salt.bytesize,
          buffer, 32
        )
        raise "Argon2id evaluation failed (code #{ret})" unless ret.zero?

        result = buffer.read_string(32)
      end
      result
    end

    # Verify a proof: one Argon2id eval + leading-zero-bits check.
    #
    # CHEAP relative to solving (~2^d evals on the client side), but costs `m`
    # KiB of memory — the provider's ASIC-resistance tunable.
    # Exactly ONE eval; no loop.
    #
    # @param salt   [String]  raw bytes (≥ 8 bytes)
    # @param params [Hash]    as returned by {.params}
    # @param nonce  [#to_s]
    # @return [Boolean]
    def self.verify(salt:, params:, nonce:)
      leading_zero_bits(digest(salt:, params:, nonce:)) >= params[:d]
    end

    # Count the number of leading zero BITS in a binary digest string.
    #
    # Spans bytes: a fully-zero byte contributes 8, then continues into the
    # next byte. Matches the semantics of
    # {Kiosk::Server::ProofOfWork.leading_zero_bits}.
    #
    # @param bytes [String] raw binary bytes (e.g. the 32-byte Argon2id output)
    # @return [Integer]
    def self.leading_zero_bits(bytes)
      return 0 if bytes.empty?

      count = 0
      bytes.each_byte do |b|
        if b == 0
          count += 8
        else
          # Integer#bit_length returns the number of bits needed to represent b
          # (position of the highest set bit + 1), so 8 - bit_length = leading zeros.
          # Examples: 0x80 (128) → 8-8=0; 0x40 (64) → 8-7=1; 0x02 (2) → 8-2=6.
          count += 8 - b.bit_length
          break
        end
      end
      count
    end
  end
end
