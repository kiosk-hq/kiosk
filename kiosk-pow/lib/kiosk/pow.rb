# frozen_string_literal: true

require 'ffi'
require 'argon2'

require 'kiosk/pow/version'

module Kiosk
  # Argon2id memory-hard proof-of-work backend, dispatched by kiosk-reputation for "argon2id".
  # A nonce is valid iff leading_zero_bits(Argon2id(nonce.to_s, salt, m, t, p, v=0x13, 32 bytes)) >= d,
  # byte-identical to the Python solver.
  module Pow
    NAME = 'argon2id'
    DIGEST_BYTES = 32

    # d: required leading zero bits; m: memory in KiB.
    def self.params(d:, m: 65_536, t: 1, p: 1) # rubocop:disable Naming/MethodParameterName -- m, t, p and d are the wire params keys.
      { m:, t:, p:, d: }
    end

    def self.digest(salt:, params:, nonce:)
      buffer = FFI::MemoryPointer.new(:char, DIGEST_BYTES)
      argon2id_hash_raw(salt, params, nonce.to_s.b, buffer)
      buffer.read_string(DIGEST_BYTES)
    ensure
      buffer&.free
    end

    # Raw libargon2 call: the Password API would turn m_cost into a power-of-two exponent.
    def self.argon2id_hash_raw(salt, params, password, buffer)
      memory, time, lanes = params.values_at(:m, :t, :p).map { Integer(it) }
      ret = Argon2::Ext.argon2id_hash_raw(time, memory, lanes, password, password.bytesize,
                                          salt, salt.bytesize, buffer, DIGEST_BYTES)
      raise "Argon2id evaluation failed (code #{ret})" unless ret.zero?
    end
    private_class_method :argon2id_hash_raw

    def self.verify(salt:, params:, nonce:) # rubocop:disable Naming/PredicateMethod -- the PoW backend interface name.
      leading_zero_bits(digest(salt:, params:, nonce:)) >= params[:d]
    end

    def self.leading_zero_bits(bytes)
      count = 0
      bytes.each_byte do |byte|
        return count + 8 - byte.bit_length unless byte.zero?

        count += 8
      end
      count
    end
  end
end
