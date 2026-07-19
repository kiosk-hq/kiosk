# frozen_string_literal: true

# Known-answer test (KAT) for the skooti RentalTokenIssuer demo lib.
#
# The skooti demo has no RSpec harness — demo behaviour is pinned by
# rake-task assertions (see lib/tasks/demo.rake). This standalone, DB-free
# self-check plays the role the kiosk-server rspec spec did before the issuer
# moved out of core: it asserts the byte-exact wire vector that
# firmware/host_test.c and firmware/skooti_lock.ino must reproduce, plus the
# issue/verify contract and the domain-separation tag gate.
#
# Run it directly (`ruby lib/rental_token_issuer_kat.rb`) or via the wired
# rake task (`rake demo:kat`). Exit status is nonzero on any failed assertion.
#
# Known-answer vector (firmware host-test fixtures — MUST NOT CHANGE):
#   dev_private_pem  = DevUnlockKey::DEV_PRIVATE_PEM
#   scooter_code     = "SK-001"
#   reservation_id   = "resv-1"
#   now              = 1750000000
#   jti (stubbed)    = "aabbccddeeff00112233445566778899"
#
#   message         : kiosk-rental-v1|SK-001|resv-1|1750000000|1750000900|aabbccddeeff00112233445566778899
#   signature b64url: 1Vx7nv8xgznLwWgdsS_MhWi1W1fhMQQWSgi1CPRVO3osohmlw_PhaTS9ZJaBOx9yeQZfzn2k8J4JjSXPd12SBA
#   pubkey hex      : 8857880d21f87b85872f31aeea8d0024acebb2fdf933b25a479f4f9e80babefd

require "openssl"
require "base64"
require "securerandom"

lib_dir = File.expand_path(__dir__)
$LOAD_PATH.unshift(lib_dir) unless $LOAD_PATH.include?(lib_dir)

# Minimal config carrier so the KAT runs without booting the full Rails app.
# The real demo defines the same `unlock_signing_key` accessor on
# Kiosk::Configuration in config/initializers/kiosk.rb; here we stand up just
# enough of Kiosk.configuration for RentalTokenIssuer to read the key.
unless defined?(Kiosk) && Kiosk.respond_to?(:configuration)
  module Kiosk
    # Tiny config object exposing only what RentalTokenIssuer reads.
    class KatConfig
      attr_accessor :unlock_signing_key
    end

    def self.configuration
      @configuration ||= KatConfig.new
    end

    def self.reset!
      @configuration = KatConfig.new
    end
  end
end

require "dev_unlock_key"
require "rental_token_issuer"

module RentalTokenIssuerKAT
  DEV_PUBKEY_HEX  = "8857880d21f87b85872f31aeea8d0024acebb2fdf933b25a479f4f9e80babefd"
  KNOWN_MESSAGE   = "kiosk-rental-v1|SK-001|resv-1|1750000000|1750000900|aabbccddeeff00112233445566778899"
  KNOWN_SIG_B64   = "1Vx7nv8xgznLwWgdsS_MhWi1W1fhMQQWSgi1CPRVO3osohmlw_PhaTS9ZJaBOx9yeQZfzn2k8J4JjSXPd12SBA"
  KNOWN_JTI       = "aabbccddeeff00112233445566778899"

  class << self
    def run
      @failures = []
      Kiosk.configuration.unlock_signing_key = DevUnlockKey.private_key

      check_issue_format
      check_verify
      check_public_key
      check_known_answer_vector
      check_domain_separation
      check_input_and_key_guards

      if @failures.empty?
        puts "OK  RentalTokenIssuer KAT — all #{@passed} assertions passed"
        true
      else
        @failures.each { |f| puts "FAIL  #{f}" }
        puts "#{@failures.size} failed assertion(s)"
        false
      end
    end

    private

    def assert(label, cond)
      @passed = (@passed || 0)
      if cond
        @passed += 1
      else
        @failures << label
      end
    end

    def check_issue_format
      token = RentalTokenIssuer.issue(scooter_code: "SK-001", reservation_id: "resv-42", now: 1_750_000_000)
      parts = token.split(".")
      assert("issue: wire format has >=2 dot-parts", parts.length >= 2)
      message_parts = parts[..-2].join(".").split("|")
      assert("issue: message has 6 pipe fields", message_parts.length == 6)

      token = RentalTokenIssuer.issue(scooter_code: "SK-007", reservation_id: "resv-99", now: 1_750_000_000)
      message = token.split(".")[..-2].join(".")
      assert("issue: embeds tag/scooter/reservation", message.start_with?("kiosk-rental-v1|SK-007|resv-99|"))

      token  = RentalTokenIssuer.issue(scooter_code: "SK-001", reservation_id: "resv-1", now: 1_750_000_000)
      fields = token.split(".")[..-2].join(".").split("|")
      assert("issue: iat = now",            fields[3].to_i == 1_750_000_000)
      assert("issue: exp = now + 900",      fields[4].to_i == 1_750_000_000 + 900)

      token  = RentalTokenIssuer.issue(scooter_code: "SK-001", reservation_id: "resv-1", now: 1_750_000_000, ttl: 300)
      fields = token.split(".")[..-2].join(".").split("|")
      assert("issue: custom ttl respected", fields[4].to_i == 1_750_000_000 + 300)

      token = RentalTokenIssuer.issue(scooter_code: "SK-001", reservation_id: "resv-1", now: 1_750_000_000)
      jti   = token.split(".")[..-2].join(".").split("|").last
      assert("issue: jti is 32 hex chars", jti.match?(/\A[0-9a-f]{32}\z/))

      opts = { scooter_code: "SK-001", reservation_id: "resv-1", now: 1_750_000_000 }
      assert("issue: fresh jti per call", RentalTokenIssuer.issue(**opts) != RentalTokenIssuer.issue(**opts))
    end

    def check_verify
      token  = RentalTokenIssuer.issue(scooter_code: "SK-001", reservation_id: "resv-42", now: 1_750_000_000)
      claims = RentalTokenIssuer.verify(token: token, now: 1_750_000_000)
      assert("verify: round-trip returns claims",   !claims.nil?)
      assert("verify: scooter_code",   claims && claims[:scooter_code] == "SK-001")
      assert("verify: reservation_id", claims && claims[:reservation_id] == "resv-42")
      assert("verify: iat",            claims && claims[:iat] == 1_750_000_000)
      assert("verify: exp",            claims && claims[:exp] == 1_750_000_000 + 900)
      assert("verify: jti hex",        claims && claims[:jti].match?(/\A[0-9a-f]{32}\z/))

      tampered = token[0..-2] + (token[-1] == "A" ? "B" : "A")
      assert("verify: tampered sig -> nil", RentalTokenIssuer.verify(token: tampered, now: 1_750_000_000).nil?)

      sig_b64  = token.split(".").last
      message  = token.split(".")[..-2].join(".")
      tampered = message.sub("SK-001", "SK-999") + ".#{sig_b64}"
      assert("verify: tampered fields -> nil", RentalTokenIssuer.verify(token: tampered, now: 1_750_000_000).nil?)

      expired = RentalTokenIssuer.issue(scooter_code: "SK-001", reservation_id: "resv-1", now: 1_750_000_000)
      assert("verify: expired (now>exp) -> nil", RentalTokenIssuer.verify(token: expired, now: 1_750_000_000 + 900 + 1).nil?)

      boundary = RentalTokenIssuer.verify(token: expired, now: 1_750_000_000 + 900)
      assert("verify: now==exp inclusive -> claims", !boundary.nil?)

      assert("verify: garbage -> nil", RentalTokenIssuer.verify(token: "garbage", now: 1_750_000_000).nil?)
      assert("verify: empty -> nil",   RentalTokenIssuer.verify(token: "", now: 1_750_000_000).nil?)
    end

    def check_public_key
      pem = RentalTokenIssuer.public_key_pem
      assert("public_key_pem: contains PUBLIC KEY", pem.include?("BEGIN PUBLIC KEY"))

      pub   = OpenSSL::PKey.read(pem)
      token = RentalTokenIssuer.issue(scooter_code: "SK-001", reservation_id: "r-1", now: 1_750_000_000)
      sig   = Base64.urlsafe_decode64(token.split(".").last)
      msg   = token.split(".")[..-2].join(".")
      assert("public_key_pem: verifies issuer sig", pub.verify(nil, sig, msg))

      hex = RentalTokenIssuer.public_key_raw32_hex
      assert("public_key_raw32_hex: 64 hex chars", hex.match?(/\A[0-9a-f]{64}\z/))
      assert("public_key_raw32_hex: matches fixture", hex == DEV_PUBKEY_HEX)
    end

    def check_known_answer_vector
      with_stubbed_jti do
        token   = RentalTokenIssuer.issue(scooter_code: "SK-001", reservation_id: "resv-1", now: 1_750_000_000)
        sig_b64 = token.split(".").last
        message = token.split(".")[..-2].join(".")
        assert("KAT: exact known message", message == KNOWN_MESSAGE)
        assert("KAT: exact known signature", sig_b64 == KNOWN_SIG_B64)
      end

      wire   = "#{KNOWN_MESSAGE}.#{KNOWN_SIG_B64}"
      claims = RentalTokenIssuer.verify(token: wire, now: 1_750_000_000)
      assert("KAT: known token verifies at iat", !claims.nil?)
      assert("KAT: known token scooter_code",    claims && claims[:scooter_code] == "SK-001")
      assert("KAT: known token reservation_id",  claims && claims[:reservation_id] == "resv-1")
      assert("KAT: known pubkey hex", RentalTokenIssuer.public_key_raw32_hex == DEV_PUBKEY_HEX)
    end

    def check_domain_separation
      valid = with_stubbed_jti do
        RentalTokenIssuer.issue(scooter_code: "SK-001", reservation_id: "resv-1", now: 1_750_000_000)
      end
      sig_b64          = valid.split(".").last
      message          = valid.split(".")[..-2].join(".")
      tampered_message = message.sub("kiosk-rental-v1", "kiosk-rental-v0")
      tampered_token   = "#{tampered_message}.#{sig_b64}"
      assert("domain-sep: wrong tag -> nil", RentalTokenIssuer.verify(token: tampered_token, now: 1_750_000_000).nil?)
    end

    # The unconfigured-key raise, verify's nil-public-key return, and the
    # pipe field-shift hazard (a `|` in an input mints a signed token this
    # issuer's own verifier rejects — see the RentalTokenIssuer.issue charset
    # contract). Saves/restores the configured key so it exercises the nil path.
    def check_input_and_key_guards
      # ── Pipe in an input: valid signature, but 8 pipe fields, so self-verify
      #    rejects it (field-shift hazard the charset contract warns about).
      poisoned = RentalTokenIssuer.issue(
        scooter_code: "SK|001", reservation_id: "resv|1", now: 1_750_000_000,
      )
      poison_fields = poisoned.split(".")[..-2].join(".").split("|")
      assert("pipe-input: message has >6 fields", poison_fields.length > 6)
      assert("pipe-input: own verify rejects -> nil",
        RentalTokenIssuer.verify(token: poisoned, now: 1_750_000_000).nil?)

      # ── Unconfigured key: issue raises, verify returns nil (no key to derive).
      saved = Kiosk.configuration.unlock_signing_key
      Kiosk.configuration.unlock_signing_key = nil
      raised = begin
        RentalTokenIssuer.issue(scooter_code: "SK-001", reservation_id: "r", now: 1_750_000_000)
        false
      rescue ArgumentError
        true
      end
      assert("unconfigured-key: issue raises ArgumentError", raised)
      assert("unconfigured-key: verify -> nil",
        RentalTokenIssuer.verify(token: "anything.sig", now: 1_750_000_000).nil?)
    ensure
      Kiosk.configuration.unlock_signing_key = saved
    end

    # Temporarily pin SecureRandom.hex(16) to the fixture jti so the KAT
    # vector is deterministic, then restore the real implementation.
    def with_stubbed_jti
      original = SecureRandom.method(:hex)
      SecureRandom.define_singleton_method(:hex) do |n = nil|
        n == 16 ? KNOWN_JTI : original.call(n)
      end
      yield
    ensure
      SecureRandom.define_singleton_method(:hex, original)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  exit(RentalTokenIssuerKAT.run ? 0 : 1)
end
