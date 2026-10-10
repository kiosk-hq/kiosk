# frozen_string_literal: true

require "test_helper"

# The lock firmware and the simulator are pinned to these bytes.
class RentalTokenIssuerTest < ActiveSupport::TestCase
  NOW         = 1_750_000_000
  PUBLIC_KEY  = "b39f3a0333c662d3937684f21c91f7722161f8b0b4f4a79b336b463eb8f570f4"
  JTI         = "aabbccddeeff00112233445566778899"
  MESSAGE     = "kiosk-rental-v1|SK-001|resv-1|1750000000|1750000900|#{JTI}"
  SIGNATURE   = "SDKHoyU3zzqvpVCwOcKf75EMJCyNKaxuRbvY3HmuM-q--ZaMEdeSmBi40JgZyhvBuL4A15xlupYqlGMfCnROCg"

  def issue(scooter_code: "SK-001", reservation_id: "resv-1", **) = RentalTokenIssuer.issue(scooter_code:, reservation_id:, now: NOW, **)
  def verify(token, now: NOW) = RentalTokenIssuer.verify(token:, now:)
  def fields(token) = token.rpartition(".").first.split("|")

  def with_known_jti
    hex = SecureRandom.method(:hex)
    SecureRandom.define_singleton_method(:hex) { |n = nil| n == 16 ? JTI : hex.call(n) }
    yield
  ensure
    SecureRandom.define_singleton_method(:hex, hex)
  end

  test "the known answer" do
    with_known_jti { assert_equal "#{MESSAGE}.#{SIGNATURE}", issue }
    assert_equal PUBLIC_KEY, RentalTokenIssuer.public_key_raw32_hex
    assert_equal "SK-001", verify("#{MESSAGE}.#{SIGNATURE}")[:scooter_code]
  end

  test "a token carries its scooter, reservation, lifetime and a fresh jti" do
    assert_equal ["kiosk-rental-v1", "SK-007", "resv-99", NOW.to_s, (NOW + 900).to_s], fields(issue(scooter_code: "SK-007", reservation_id: "resv-99")).first(5)
    assert_match(/\A\h{32}\z/, fields(issue).last)
    assert_not_equal issue, issue
  end

  test "verify answers the claims, and only for an intact live token" do
    token = issue
    assert_equal({ scooter_code: "SK-001", reservation_id: "resv-1", iat: NOW, exp: NOW + 900 }, verify(token).except(:jti))
    assert verify(token, now: NOW + 899)
    assert_nil verify(token, now: NOW + 900)
    assert_nil verify(token.sub(/.\z/) { _1 == "A" ? "B" : "A" })
    assert_nil verify(token.sub("SK-001", "SK-999"))
    assert_nil verify(token.sub("kiosk-rental-v1", "kiosk-rental-v0"))
    assert_nil verify("garbage")
    assert_nil verify("")
  end

  test "the published public key verifies the signature" do
    message, _, signature = issue.rpartition(".")
    assert OpenSSL::PKey.read(RentalTokenIssuer.public_key_pem).verify(nil, Base64.urlsafe_decode64(signature), message)
  end

  test "a field that would break the format is refused" do
    [["SK|001", "resv-1"], ["SK-001", "resv|1"], ["SK 001", "resv-1"], ["SK-001", "resv 1"],
     ["SK-001", "resv\xFF1".b], ["", "resv-1"], ["SK-001", ""]].each do |scooter_code, reservation_id|
      assert_raises(ArgumentError) { issue(scooter_code:, reservation_id:) }
    end
    assert verify(issue(reservation_id: SecureRandom.uuid))
  end

  test "without a signing key nothing is issued or verified" do
    key = Kiosk.configuration.unlock_signing_key
    Kiosk.configuration.unlock_signing_key = nil
    assert_raises(ArgumentError) { issue }
    assert_nil verify("anything.sig")
  ensure
    Kiosk.configuration.unlock_signing_key = key
  end
end
