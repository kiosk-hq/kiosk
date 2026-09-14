# frozen_string_literal: true

# crosscheck_grammar.rb — the rental-token grammar, run through all THREE
# readers of the token at once.
#
# Invoked by `make crosscheck` as:
#   ruby crosscheck_grammar.rb ./host_test_crosscheck
#
# `make crosscheck`'s first half proves the C verifier ACCEPTS a token the Ruby
# side just signed. This is the other half of the same question, and the harder
# one: the three implementations must agree on what they REFUSE. They are
# independent parsers by design — C walks the pipes by hand, `String#split`
# does it in Ruby twice over, and each language brings its own base64 decoder —
# and they pull apart at places that are properties of the languages rather
# than slips anyone can review away. token_vectors.rb's header lists them.
#
# None of that is reachable through the shipped flow — the issuer mints iat,
# exp and jti itself, and the one caller-supplied field that reaches the message
# is UUID-checked first. It would still be three answers to one question, in a
# reference implementation people copy, and the reader that answers WIDEST is
# the one that decides what a fleet accepts. Which reader that is varies by
# axis: on the integer syntax the Ruby pair is the wide one, on the base64 tail
# the lock is, and an adopter who reads only the reader nearest to hand cannot
# tell. That is the whole argument for running all three against one set.
#
# So this script does not review the parsers. It runs every reader against ONE
# vector set — token_vectors.rb, whose header states the grammar and what it
# does not cover — and fails when any reader's answer differs from the answer
# the set declares. The Ruby halves call the SHIPPED code, not a copy:
# `RentalTokenIssuer.verify` from app/services and `LockSim#unlock` from
# script/, exactly as the server and the flow drivers call them.
#
# Every vector's signature is computed here, at run time, with the live dev key
# in ../config/dev_unlock_key.pem — the same key the server signs with — over
# that vector's own message. The vector then declares how the wire token is
# SPELLED around that signature, and this script applies the spelling from the
# set's own `WIRE` table.
#
# THE C READER IS ASKED THROUGH A FILE, not through argv, for every vector.
# execve() delimits arguments with NUL, so a token holding one cannot travel in
# argv at all — and that byte is exactly where the C reader and a Ruby reader
# see different tokens. Handing every vector to the helper the same way keeps
# one code path and leaves no vector the set cannot ask all three readers.

require "openssl"
require "base64"
require "tempfile"

HELPER = ARGV[0]
if HELPER.nil? || HELPER.empty?
  abort "usage: ruby crosscheck_grammar.rb <path to host_test_crosscheck>"
end

# Minimal config carrier so the issuer loads without booting Rails — the same
# shape script/rental_token_issuer_kat.rb stands up for the same reason.
unless defined?(Kiosk) && Kiosk.respond_to?(:configuration)
  module Kiosk
    # Exposes only the accessor RentalTokenIssuer reads.
    class CrosscheckConfig
      attr_accessor :unlock_signing_key
    end

    def self.configuration
      @configuration ||= CrosscheckConfig.new
    end
  end
end

require_relative "token_vectors"
require File.expand_path("../app/services/rental_token_issuer", __dir__)
require File.expand_path("../script/lock_sim", __dir__)

KEY = OpenSSL::PKey.read(File.read(File.expand_path("../config/dev_unlock_key.pem", __dir__)))
Kiosk.configuration.unlock_signing_key = KEY
PUBLIC_KEY = OpenSSL::PKey.read(KEY.public_to_pem)

NOW  = SkootiTokenVectors::NOW
CODE = SkootiTokenVectors::SCOOTER_CODE
WIRE = SkootiTokenVectors::WIRE

# The canonical signature over a message: unpadded base64url, as the issuer
# mints it.
def sign(message)
  Base64.urlsafe_encode64(KEY.sign(nil, message), padding: false)
end

# The wire token a vector asks for. A vector whose spelling is NOT :canonical
# and whose transform returns the canonical token measures nothing, so that is
# a hard stop rather than a quiet pass.
def wire_token(vector)
  signature = sign(vector.message)
  transform = WIRE.fetch(vector.wire)
  token     = transform.call(vector.message, signature)

  if vector.wire != :canonical && token == WIRE.fetch(:canonical).call(vector.message, signature)
    abort "  VECTOR BROKEN — #{vector.axis}/#{vector.label}: the :#{vector.wire} " \
          "spelling produced the canonical token, so this vector measures nothing"
  end

  token
end

# The C verifier, through the helper binary `make crosscheck` builds, asked via
# --file so a token holding a NUL reaches it exactly as a BLE write would. Its
# exit status is the verdict: 0 accepted, 1 refused.
def c_accepts?(token)
  file = Tempfile.new(["skooti-vector", ".tok"])
  begin
    file.binmode
    file.write(token)
    file.close
    system(HELPER, "--file", file.path, out: File::NULL)
  ensure
    file.unlink
  end
end

def issuer_accepts?(token)
  !RentalTokenIssuer.verify(token: token, now: NOW).nil?
end

# A fresh lock per vector, so the replay store of one vector cannot answer for
# the next — replay is per-reader state and is not what this set measures.
def lock_sim_accepts?(token)
  LockSim.new(scooter_code: CODE, skooti_public_key: PUBLIC_KEY).unlock(token: token, now: NOW)
end

# [column heading, full name for the failure report, probe]
READERS = [
  ["C",      "C skooti_verify_token",    method(:c_accepts?)],
  ["issuer", "RentalTokenIssuer.verify", method(:issuer_accepts?)],
  ["lock",   "LockSim#unlock",           method(:lock_sim_accepts?)],
].freeze

VECTORS  = SkootiTokenVectors::VECTORS
RESPELT  = VECTORS.count { |vector| vector.wire != :canonical }
ROW      = "    %-6s %-46s %-7s %-7s %-7s %-7s %s"

puts "  Rental-token grammar — #{VECTORS.length} live-signed vectors through " \
     "all #{READERS.length} readers of this token " \
     "(#{RESPELT} of them respell the wire around the signature):"
puts format(ROW, "axis", "vector", "expect", *READERS.map(&:first), "")

failures = []

VECTORS.each do |vector|
  token   = wire_token(vector)
  answers = READERS.map { |_head, _name, probe| probe.call(token) }
  agreed  = answers.all? { |answer| answer == vector.accept }
  failures << [vector, answers] unless agreed

  puts format(ROW, vector.axis, vector.label,
              vector.accept ? "accept" : "reject",
              *answers.map { |answer| answer ? "accept" : "reject" },
              agreed ? "MATCH ✓" : "MISMATCH ✗")
end

if failures.empty?
  puts "  MATCH — all #{READERS.length} readers gave the declared answer on " \
       "every one of these #{VECTORS.length} vectors " \
       "(axes: #{SkootiTokenVectors.axes.join(', ')}) ✓"
  exit 0
end

puts "  MISMATCH — #{failures.length} of #{VECTORS.length} vector(s) did not get " \
     "the declared answer from all #{READERS.length} readers ✗"
failures.each do |vector, answers|
  disagreeing = READERS.zip(answers)
                       .reject { |_reader, answer| answer == vector.accept }
                       .map { |reader, _answer| reader[1] }
  puts "    #{vector.axis}/#{vector.label}: declared " \
       "#{vector.accept ? 'accept' : 'reject'}, answered the other way by " \
       "#{disagreeing.join(', ')}"
end
exit 1
