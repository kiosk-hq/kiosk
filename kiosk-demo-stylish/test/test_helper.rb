# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"

require_relative "../config/environment"
require "rails/test_help"

require "kiosk/server/conformance_origin"
require "kiosk/test_helpers/conformance/minitest"
require "kiosk/story_test"

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
end

# Alice and Bob book at Combette on Park, and the owner runs it. Each links an
# assistant to their own salon account.
class StoryTest < Kiosk::StoryTest
  PEOPLE = { alice: "alice@example.com", bob: "bob@example.com", owner: "owner@combette.example" }.freeze

  def signs_in(person) = a_person(email: PEOPLE.fetch(person), password: "combette-demo-password")
  def account_of(person) = User.find_by!(email: PEOPLE.fetch(person)).id

  # A fresh assistant pays the registration toll, then claims a link code the person mints.
  def assistant_of(person) = signs_in(person).links(a_customer(as: Client))
end
