# frozen_string_literal: true

require "ffi"
require "argon2"

require "kiosk/pow/version"

module Kiosk
  # Argon2id memory-hard proof-of-work backend, dispatched by kiosk-reputation for "argon2id".
  # A nonce is valid iff leading_zero_bits(Argon2id(nonce.to_s, salt, m, t, p, v=0x13, 32 bytes)) >= d,
  # byte-identical to the Python solver.
  module Pow
    NAME = "argon2id"

    # d: required leading zero bits; m: memory in KiB.
    def self.params(d:, m: 65_536, t: 1, p: 1)
      { m:, t:, p:, d: }
    end

    # Raw libargon2 call: the Password API would turn m_cost into a power-of-two exponent.
    def self.digest(salt:, params:, nonce:)
      password = nonce.to_s.b
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

    def self.verify(salt:, params:, nonce:)
      leading_zero_bits(digest(salt:, params:, nonce:)) >= params[:d]
    end

    def self.leading_zero_bits(bytes)
      return 0 if bytes.empty?

      count = 0
      bytes.each_byte do |b|
        if b == 0
          count += 8
        else
          count += 8 - b.bit_length
          break
        end
      end
      count
    end
  end
end
