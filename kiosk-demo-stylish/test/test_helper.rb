# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"

require_relative "../config/environment"
require "rails/test_help"

require "kiosk/server/conformance_origin"
require "kiosk/test_helpers/conformance/minitest"
require "kiosk/story_test"
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

# A salon client's AI assistant: finds the salon, books a service off its menu and
# looks at what it has booked. The owner's assistant reads the whole book.
class Client < Kiosk::TestHelpers::Customer
  def salons = asks(:salons).rows
  def menu = asks(:service_menu).rows
  def appointments = asks(:my_appointments).rows.pluck("id")
  def the_book = asks(:salon_calendar)

  def books(service = nil, at: 1.week.from_now, **extra)
    picked = menu.find { _1["name"] == service } if service
    does(:book_appointment, salon_id: salons.first["salon_id"], slot: at.iso8601,
                            **{ service_id: picked&.fetch("service_id") }.compact, **extra)
  end

  # Whose salon account the assistant acts for, and in which role, as the salon signed it.
  def account = signed["sub"]
  def role = signed["role"]

  # An unlinked assistant is no longer known when it signs in with its own key.
  def signs_back_in
    Kiosk::TestHelpers::Answer.new(@assistant.wire.post("/kiosk/auth/login", public_key: principal.rsa_key.public_key.to_pem,
                                                                              signed: Client.proof(origin, principal.rsa_key)))
  end

  # A possession proof for `key`, over a fresh challenge from the salon.
  def self.proof(origin, key)
    _, challenge = Kiosk::TestHelpers::Wire.new(base_url: origin).get_json("/kiosk/auth/challenge", public_key: key.public_key.to_pem)
    JWT.encode({ aud: origin, nonce: challenge.fetch("challenge"), jti: SecureRandom.uuid, iat: Time.now.to_i }, key, "RS256")
  end

  private

  def signed = JWT.decode(principal.token, nil, false).first
end

# Alice and Bob book at Combette on Park, and the owner runs it. Each links an
# assistant to their own salon account.
class StoryTest < Kiosk::StoryTest
  PEOPLE = { alice: "alice@example.com", bob: "bob@example.com", owner: "owner@combette.example" }.freeze

  def signs_in(person)
    Kiosk::UserIdentityProviders::DeviseSession.new(live_url).sign_in!(email: PEOPLE.fetch(person),
                                                                       password: "combette-demo-password")
  end

  def account_of(person) = User.find_by!(email: PEOPLE.fetch(person)).id

  # A fresh assistant pays the registration toll, then claims a link code the person mints.
  def assistant_of(person)
    key = register.rsa_key
    _, link = signs_in(person).post_json("/kiosk/auth/link", {}, { session: true })
    status, claimed = assistant.wire.post_json("/kiosk/auth/claim", code: link.fetch("link_code"),
                                                                    public_key: key.public_key.to_pem,
                                                                    signed: Client.proof(live_url, key))
    assert_equal 201, status, claimed
    principal = Kiosk::TestHelpers::Assistant::Principal.new(agent_id: claimed["agent_id"], user_id: claimed["user_id"],
                                                             token: claimed["access_token"], rsa_key: key)
    Client.new(assistant, principal)
  end
end
