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
#
# THE RUBY READERS ARE ASKED UNDER THE VECTOR'S OWN ENCODING TAG. A Ruby String
# carries one and every string operation consults it, so it is an input to the
# verdict exactly as the bytes are — and it is an input the C reader does not
# have. The `encoding` axis varies it over one set of bytes; every other vector
# declares UTF-8, which is what a token arriving from a request parameter or a
# File.read is tagged with here.
#
# A READER THAT RAISES IS REPORTED, NOT CRASHED INTO. Both Ruby readers
# document what they return on failure — "nil on any failure", "Returns false
# if …" — and an exception outside that list is the documentation being wrong
# rather than a bug in this runner. So a probe that raises prints the exception
# class in its column and counts as a disagreement, which is how a vector that
# finds one names the reader instead of killing the run.
#
# THE SWEEP IS RUN AS A CENSUS. token_vectors.rb's readable VECTORS are printed
# a row each; its SWEEP — one vector per byte value for each opaque field — is
# run through the same three readers and reported as a count, because 446 lines
# of MATCH hide the rows a reader came for. Any disagreement inside it is named
# individually. The sweep's exhaustiveness is asserted here rather than assumed:
# a run whose reservation_id arm does not reach all 256 byte values is a run
# whose census means nothing, and it aborts.

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

# The wire token a vector asks for, as BYTES. A vector whose spelling is NOT
# :canonical and whose transform returns the canonical token measures nothing,
# so that is a hard stop rather than a quiet pass.
def wire_token(vector)
  signature = sign(vector.message)
  transform = WIRE.fetch(vector.wire)
  token     = transform.call(vector.message, signature).b

  if vector.wire != :canonical &&
     token == WIRE.fetch(:canonical).call(vector.message, signature).b
    abort "  VECTOR BROKEN — #{vector.axis}/#{vector.label}: the :#{vector.wire} " \
          "spelling produced the canonical token, so this vector measures nothing"
  end

  token
end

# The same bytes under the tag the vector declares. The C reader is handed a
# file and never sees this; the two Ruby readers see nothing else.
def tagged_token(vector)
  wire_token(vector).dup.force_encoding(vector.tag)
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

# A reader that RAISES has given neither answer, and that is a result rather
# than a crash: both Ruby readers document a list of what they return on
# failure, so an exception outside it is the documentation being wrong. Named
# as its own verdict so a run says which reader and which exception, instead of
# the runner dying on the vector that found it.
def answer(probe, token)
  probe.call(token)
rescue StandardError => e
  e.class.name
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
SWEEP    = SkootiTokenVectors::SWEEP
RESPELT  = VECTORS.count { |vector| vector.wire != :canonical }
TAGGED   = VECTORS.count { |vector| vector.tag != SkootiTokenVectors::DEFAULT_TAG }
ROW      = "    %-8s %-46s %-7s %-7s %-7s %-7s %s"

# The sweep only means something if it reaches every byte value it claims to.
# Re-derived from the vectors' own messages, not from the range that built
# them, and a short arm is a hard stop: a census over a sample would read
# exactly like a census over the domain.
COVERAGE = SkootiTokenVectors.sweep_coverage
unless COVERAGE.fetch("reservation_id") == (0..255).to_a
  abort "  SWEEP BROKEN — the reservation_id arm reaches " \
        "#{COVERAGE.fetch('reservation_id').length} byte values, not all 256, " \
        "so nothing here can say what the other bytes do"
end

# Run one vector through all three readers. Returns [answers, agreed].
def ask(vector)
  bytes   = wire_token(vector)
  tagged  = bytes.dup.force_encoding(vector.tag)
  answers = READERS.map { |head, _name, probe| answer(probe, head == "C" ? bytes : tagged) }
  [answers, answers.all? { |a| a == vector.accept }]
end

# How one reader's answer prints: accept, reject, or the exception class it
# raised instead of answering.
def verdict(a)
  case a
  when true  then "accept"
  when false then "reject"
  else a.to_s.split("::").last
  end
end

def name_disagreement(vector, answers)
  disagreeing = READERS.zip(answers)
                       .reject { |_reader, a| a == vector.accept }
                       .map { |reader, a| "#{reader[1]} (#{verdict(a)})" }
  "    #{vector.axis}/#{vector.label}: declared " \
    "#{vector.accept ? 'accept' : 'reject'}, answered the other way by " \
    "#{disagreeing.join(', ')}"
end

puts "  Rental-token grammar — #{VECTORS.length} live-signed vectors through " \
     "all #{READERS.length} readers of this token " \
     "(#{RESPELT} respell the wire around the signature, " \
     "#{TAGGED} vary the Ruby encoding tag):"
puts format(ROW, "axis", "vector", "expect", *READERS.map(&:first), "")

failures = []

VECTORS.each do |vector|
  answers, agreed = ask(vector)
  failures << [vector, answers] unless agreed

  puts format(ROW, vector.axis, vector.label,
              vector.accept ? "accept" : "reject",
              *answers.map { |a| verdict(a) },
              agreed ? "MATCH ✓" : "MISMATCH ✗")
end

# ── the exhaustive charset sweep, reported as a census ──────────────────────
sweep_failures = []
SWEEP.each do |vector|
  answers, agreed = ask(vector)
  sweep_failures << [vector, answers] unless agreed
end

puts "    charset sweep — every byte value 0x00-0xFF in each opaque field: " \
     "#{COVERAGE.fetch('reservation_id').length} in reservation_id " \
     "(#{SkootiTokenVectors::UNRESERVED.length} accepted, " \
     "#{256 - SkootiTokenVectors::UNRESERVED.length} refused) and " \
     "#{COVERAGE.fetch('scooter_code').length} in scooter_code (all refused), " \
     "#{SWEEP.length - sweep_failures.length} of #{SWEEP.length} agreed " \
     "#{sweep_failures.empty? ? 'MATCH ✓' : 'MISMATCH ✗'}"

failures.concat(sweep_failures)
total = VECTORS.length + SWEEP.length

if failures.empty?
  puts "  MATCH — all #{READERS.length} readers gave the declared answer on " \
       "every one of these #{total} vectors " \
       "(axes: #{SkootiTokenVectors.axes.join(', ')}) ✓"
  exit 0
end

puts "  MISMATCH — #{failures.length} of #{total} vector(s) did not get " \
     "the declared answer from all #{READERS.length} readers ✗"
failures.each { |vector, answers| puts name_disagreement(vector, answers) }
exit 1
