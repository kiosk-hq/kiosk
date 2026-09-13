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
# does it in Ruby twice over — and the two languages pull apart at three
# places, each of which is a property of the language rather than a slip
# anyone can review away:
#
#   * `String#split("|")` DROPS trailing empty fields. A signed message with
#     one delimiter appended is six fields to a reader spelled that way and
#     seven to the C parser, which finds the pipe in the last field.
#   * `Integer(s, 10)` takes a sign, underscore separators and surrounding
#     whitespace. `+1750001900` is a valid expiry to it and not a number at
#     all to `parse_uint64`.
#   * A field nothing parses is a field each reader may read differently, and
#     `iat` is the field nothing acts on.
#
# None of that is reachable through the shipped flow — the issuer mints iat,
# exp and jti itself, and the one caller-supplied field that reaches the message
# is UUID-checked first — and the lock fails closed either way. It would still
# be three answers to one question, in a reference implementation people copy.
#
# So this script does not review the parsers. It runs every reader against ONE
# vector set — token_vectors.rb, whose header states the grammar and what it
# does not cover — and fails when any reader's answer differs from the answer
# the set declares. The Ruby halves call the SHIPPED code, not a copy:
# `RentalTokenIssuer.verify` from app/services and `LockSim#unlock` from
# script/, exactly as the server and the flow drivers call them.
#
# Every vector is signed here, at run time, with the live dev key in
# ../config/dev_unlock_key.pem — the same key the server signs with — so the
# signature gate passes on all of them and the grammar is the only thing left
# to answer. A wrong-shaped message carrying a junk signature is refused by the
# signature gate first and proves nothing about the parse.

require "openssl"
require "base64"

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

def sign(message)
  "#{message}.#{Base64.urlsafe_encode64(KEY.sign(nil, message), padding: false)}"
end

# The C verifier, through the helper binary `make crosscheck` builds. Its exit
# status is the verdict: 0 accepted, 1 refused.
def c_accepts?(token)
  system(HELPER, token, out: File::NULL)
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

VECTORS = SkootiTokenVectors::VECTORS
ROW     = "    %-6s %-42s %-7s %-7s %-7s %-7s %s"

puts "  Rental-token grammar — #{VECTORS.length} live-signed vectors through " \
     "all #{READERS.length} readers of this token:"
puts format(ROW, "axis", "vector", "expect", *READERS.map(&:first), "")

failures = []

VECTORS.each do |vector|
  token   = sign(vector.message)
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
