# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"

require_relative "../config/environment"
require "rails/test_help"

require "kiosk/server/conformance_origin"
require "kiosk/test_helpers/conformance/minitest"
require "kiosk/test_helpers/live_server"
require "kiosk/redteam"
require "kiosk/user_identity_providers/devise_session"

Kiosk::TestHelpers::Conformance.origin = Kiosk::Server::ConformanceOrigin.new

module ActiveSupport
  class TestCase
    include Kiosk::TestHelpers::Conformance::Assertions

    # The registry, the router, and a GUC-scoped session with the verb's own
    # `input_schema` validated first — what the wire runs.
    def kiosk_origin = Kiosk::TestHelpers::Conformance.require_origin!

    def assert_kiosk_refused(&)
      error = assert_raises(Kiosk::Server::Errors::Base, &)
      assert_equal "bad_request", error.code
      error
    end
  end
end

# Drives this origin over HTTP as an assistant does, for the seeded humans.
class WireTest < ActiveSupport::TestCase
  include Kiosk::TestHelpers::LiveServer

  PASSWORD = "combette-demo-password"

  def client = @client ||= Kiosk::Redteam::Client.new(base_url: live_url)

  def sign_in(email) = Kiosk::UserIdentityProviders::DeviseSession.new(live_url).sign_in!(email:, password: PASSWORD)

  # A fresh assistant, registered through the toll and then bound to the human by a link code.
  def bind(email)
    assistant = client.register!(name: email)
    _, link = sign_in(email).post_json("/kiosk/auth/link", {}, { session: true })
    claim(assistant.rsa_key, link.fetch("link_code"))
  end

  def claim(key, code)
    status, claimed = post("/kiosk/auth/claim", code:, public_key: key.public_key.to_pem, signed: proof(key))
    assert_equal 201, status, claimed
    Kiosk::Redteam::Principal.new(agent_id: claimed["agent_id"], user_id: claimed["user_id"],
                                  token: claimed["access_token"], rsa_key: key)
  end

  def login(assistant) = post("/kiosk/auth/login", public_key: assistant.rsa_key.public_key.to_pem, signed: proof(assistant.rsa_key)).first

  # A possession proof for `key`, over a fresh challenge from this origin.
  def proof(key)
    _, challenge = wire.get_json("/kiosk/auth/challenge", { public_key: key.public_key.to_pem })
    JWT.encode({ aud: live_url, nonce: challenge.fetch("challenge"), jti: SecureRandom.uuid, iat: Time.now.to_i }, key, "RS256")
  end

  def book(assistant, **args)
    booked = client.run(assistant, name: "book_appointment", salon_id: Salon.first.id, slot: 1.week.from_now.iso8601, **args)
    assert_equal 200, booked.status, booked.body
    booked.body
  end

  def my_appointments(assistant) = client.query(assistant, name: "my_appointments").body.map { _1["id"] }

  def claims(assistant) = JWT.decode(assistant.token, nil, false).first

  private

  def wire = Kiosk::Redteam::Wire.new(base_url: live_url)
  def post(path, body) = wire.post_json(path, body)
end
