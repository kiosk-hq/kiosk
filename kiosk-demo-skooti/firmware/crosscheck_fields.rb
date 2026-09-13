# frozen_string_literal: true

# crosscheck_fields.rb — the field-count boundary, run through BOTH verifiers.
#
# Invoked by `make crosscheck` as:
#   ruby crosscheck_fields.rb ./host_test_crosscheck
#
# `make crosscheck`'s first half proves the C verifier ACCEPTS a token the Ruby
# side just signed. This is the other half of the same question: the two
# implementations must also agree on what they REFUSE, and the place they can
# disagree is the field count, because C splits the message by walking pipes and
# Ruby splits it with String#split.
#
# The signed message is exactly six pipe-delimited fields. Every case below is
# signed with the live dev key in ../config/dev_unlock_key.pem — the same key
# the server signs with — so the signature gate passes on all four and the field
# count is the only thing left to answer. That matters: a wrong-count message
# carrying a junk signature is refused by the signature gate first and proves
# nothing about the count.
#
# The eight-field case is what the issuer mints when a `|` reaches scooter_code
# or reservation_id — the charset contract on RentalTokenIssuer.issue names that
# input precondition. The extra field is not the damage; the SHIFT is. Every
# field moves left, field[4] stops being `exp`, and a verifier that does not
# count fields reads a caller-supplied number as the expiry — here 9999999999,
# which is the 15-minute window gone.
#
# The Ruby half calls RentalTokenIssuer.verify itself rather than reimplementing
# it, so this compares the shipped server code against the shipped lock code.

require "openssl"
require "base64"

HELPER = ARGV[0]
abort "usage: ruby crosscheck_fields.rb <path to host_test_crosscheck>" if HELPER.nil? || HELPER.empty?

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

require File.expand_path("../app/services/rental_token_issuer", __dir__)

KEY = OpenSSL::PKey.read(File.read(File.expand_path("../config/dev_unlock_key.pem", __dir__)))
Kiosk.configuration.unlock_signing_key = KEY

# The C helper verifies with now = 1750001800 and SCOOTER_CODE = "SK-001";
# every message below sits inside that window when read correctly.
NOW = 1_750_001_800

JTI = "deadbeef00112233445566778899aabb"

CASES = [
  ["5 fields  (jti absent)                 ", false,
   "kiosk-rental-v1|SK-001|resv-live|1750001000|1750001900"],
  ["6 fields  (well-formed)                ", true,
   "kiosk-rental-v1|SK-001|resv-live|1750001000|1750001900|#{JTI}"],
  ["7 fields  (one appended after the jti) ", false,
   "kiosk-rental-v1|SK-001|resv-live|1750001000|1750001900|#{JTI}|EXTRA"],
  ["8 fields  (pipe-input shift, exp faked)", false,
   "kiosk-rental-v1|SK-001|r|1750001000|9999999999|1750001000|1750001900|#{JTI}"],
].freeze

puts "  Field-count boundary — Ruby issuer verify vs C verify, same live key:"

mismatches = 0

CASES.each do |label, expect_accept, message|
  token       = "#{message}.#{Base64.urlsafe_encode64(KEY.sign(nil, message), padding: false)}"
  ruby_accept = !RentalTokenIssuer.verify(token: token, now: NOW).nil?
  c_accept    = system(HELPER, token, out: File::NULL)
  agree       = ruby_accept == expect_accept && c_accept == expect_accept
  mismatches += 1 unless agree

  puts format("    %s  Ruby %-6s  C %-6s  %s",
              label,
              ruby_accept ? "accept" : "reject",
              c_accept ? "accept" : "reject",
              agree ? "MATCH ✓" : "MISMATCH ✗")
end

if mismatches.zero?
  puts "  MATCH — both verifiers accept the 6-field message and refuse every other count ✓"
  exit 0
end

puts "  MISMATCH — #{mismatches} field-count case(s) disagree ✗"
exit 1
