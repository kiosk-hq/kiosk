# frozen_string_literal: true

require "spec_helper"

# THE FOUR PROPERTIES THE PROTOCOL MAKES NORMATIVE OF THIS ORIGIN, asserted the
# way an adopting operator on RSpec asserts them about their own.
#
# Everything Kiosk-specific here is four matcher names. There is no harness, no
# hand-rolled `assert`, no results array and no exit block: the checks ship in
# kiosk-test-support and `spec_helper.rb` wires them in three lines. What IS this
# demo's own is the fixtures and the verb names, which is the right split —
# those are the only part of a conformance suite that cannot be shared.
#
# The Minitest spelling of exactly these assertions is
# `kiosk-demo-getgrocery/test/kiosk_conformance_test.rb`. The two render the
# same failure sentence, which is what "framework-agnostic" has to cash out as.
#
# It runs with no server, no proof-of-work and no bearer token: the calls go
# through the registered handler under a GUC-scoped session, so what is asserted
# is the operator's own code rather than the wire in front of it. The wire is
# driven by `check:book`, `check:search`, `check:isolation` and `check:redteam`.
RSpec.describe "Kiosk conformance" do
  # Two guests with a booking each. `my_bookings` answers whoever is calling, so
  # a scoping assertion needs both sides seeded: one to see rows and one to be
  # refused them.
  let(:ada) { User.create!(email: "ada-conformance@example.test", password: "conformance-fixture") }
  let(:ben) { User.create!(email: "ben-conformance@example.test", password: "conformance-fixture") }

  let(:property) do
    Property.create!(name: "Gran Hotel Conformance", city: "Istanbul",
                     neighbourhood: "Beşiktaş", stars: 5, amenities: [],
                     address: "1 Barbaros Blv, Beşiktaş, Istanbul")
  end

  # TWO room types, because the schema will not let one hold two overlapping
  # stays: `bookings_no_overlapping_room_nights` is an exclusion constraint on
  # `(room_type_id, daterange(check_in, check_out))`. That is the demo's real
  # inventory rule and a fixture has to respect it like any other caller.
  let(:double) { RoomType.create!(property: property, name: "Double", nightly_price_cents: 18_000) }
  let(:suite)  { RoomType.create!(property: property, name: "Suite",  nightly_price_cents: 32_000) }

  let(:check_in)  { Date.current + 30 }
  let(:check_out) { Date.current + 32 }

  def book_for(user, room_type)
    Booking.create!(user_id: user.id, property_id: property.id, room_type_id: room_type.id,
                    check_in: check_in, check_out: check_out,
                    total_cents: room_type.nightly_price_cents * 2, status: "reserved")
  end

  before do
    book_for(ada, double)
    book_for(ben, suite)
  end

  # ── 1. THE ROUTES RESOLVE ─────────────────────────────────────────────────
  #
  # Every verb needs a line in `config/routes/kiosk.rb`, and a verb declared
  # without one is a 404 to every caller — something this app's own flow tasks
  # would notice only if one of them happened to call it. This asks the router
  # about all eight at once.
  it "routes every verb it declares, with the method its kind requires" do
    expect(kiosk_origin).to have_a_route_for_every_verb
  end

  # ── 2. A VERB EXECUTES ────────────────────────────────────────────────────
  #
  # With no `params:` given, each matcher runs the verb's OWN `example_params` —
  # the object the descriptor tells an assistant to copy — so this executes the
  # published example as well as the handler. `search_hotels` and
  # `hotel_detail` both publish one; `properties` and `my_bookings` take
  # nothing.
  it "executes its read surface as an authenticated principal" do
    expect(:properties).to    execute_as_a_kiosk_verb(as: ada)
    expect(:my_bookings).to   execute_as_a_kiosk_verb(as: ada)
    expect(:search_hotels).to execute_as_a_kiosk_verb(as: ada)
  end

  # ── 3. A QUERY ANSWERS THE SHAPE IT DECLARED ──────────────────────────────
  #
  # `output_schema` is the only machine-readable statement of what a call
  # returns, so a descriptor that mis-states it is worse than one that says
  # nothing: the assistant shapes its parse from it and never meets the handler
  # that disagrees. Same validator the engine runs with `validate_responses` on,
  # so this and a running server cannot differ.
  it "answers the shape `properties` publishes" do
    expect(:properties).to answer_its_declared_schema(as: ada)
  end

  it "answers the shape `my_bookings` publishes" do
    expect(:my_bookings).to answer_its_declared_schema(as: ada)
  end

  it "answers the shape `search_hotels` publishes, running its own example" do
    expect(:search_hotels).to answer_its_declared_schema(as: ada)
  end

  it "answers the shape `availability` publishes" do
    expect(:availability).to answer_its_declared_schema(
      as: ada,
      params: { property_id: property.id,
                check_in:  check_in.iso8601,
                check_out: check_out.iso8601 },
    )
  end

  # ── 4. DATA ACCESS IS SCOPED TO THE PRINCIPAL ─────────────────────────────
  #
  # `my_bookings` declares no `reach`, which means `principal` — the strongest
  # claim in the descriptor and the one made by saying nothing. The assertion is
  # that no row ada sees reaches ben, and it carries its own positive control:
  # it fails if ada sees nothing, because a verb that answers everybody with
  # nothing would otherwise satisfy it while broken.
  #
  # Watched fail: change `Booking.owned_by_current_principal` to `Booking.all`
  # and this names the leaked rows and the confirmation codes in them.
  it "hands one guest nothing belonging to another" do
    expect(:my_bookings).to be_scoped_to_principal(as: ada, and_not: ben)
  end

  # The counterpart, and it is the one that would be a bug the other way round:
  # `properties` is the public shelf, so the two principals SHOULD see the same
  # rows. The scoping matcher refuses to run on a verb declared
  # `reach: :published` rather than asserting the opposite of its descriptor —
  # so this asserts the descriptor instead, which is what that refusal is for.
  it "publishes the same shelf to every principal" do
    ada_shelf = Kiosk::TestHelpers::Conformance.executes(:properties, as: ada)
    ben_shelf = Kiosk::TestHelpers::Conformance.executes(:properties, as: ben)

    expect(ada_shelf).to be_ok
    expect(ben_shelf).to be_ok
    expect(ada_shelf.details[:answer]).to eq(ben_shelf.details[:answer])
  end
end
