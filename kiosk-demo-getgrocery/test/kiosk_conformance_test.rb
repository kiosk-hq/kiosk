# frozen_string_literal: true

require "test_helper"

# THE FOUR PROPERTIES THE PROTOCOL MAKES NORMATIVE OF THIS ORIGIN, asserted the
# way an adopting operator asserts them about their own.
#
# Everything Kiosk-specific in this file is four assertion names. There is no
# harness here, no hand-rolled `assert`, no results array and no exit block: the
# checks ship in kiosk-test-support and `test/test_helper.rb` wires them in
# three lines. What IS this demo's own is the fixtures and the verb names —
# which is the right split, because those are the only part of a conformance
# suite that cannot be shared.
#
# It runs with no server, no proof-of-work and no bearer token: the calls go
# through the registered handler under a GUC-scoped session, so what is being
# asserted is the operator's own code rather than the wire in front of it. The
# wire itself is driven by `check:shop`, `check:isolation` and `check:redteam`.
class KioskConformanceTest < ActiveSupport::TestCase
  # Two principals with a shopping history each. `my_orders` answers whoever is
  # calling, so a scoping assertion needs both sides seeded: one to see rows and
  # one to be refused them.
  setup do
    @alice = User.create!(email: "alice@example.test", password: "conformance-fixture-password")
    @bob   = User.create!(email: "bob@example.test",   password: "conformance-fixture-password")

    @bread = Product.create!(sku: "sourdough-bread", name: "Sourdough Bread",
                             price_cents: 449, stock: 20)

    # `timezone` is spelled out rather than defaulted: `orders.timezone` carries
    # no column default on purpose, so anything that writes an order has to say
    # which clock it was quoted on. A fixture is no exception — a row that could
    # not name its clock is a row the wire could not have produced.
    @alice_order = Order.create!(user: @alice, status: Order::CREATED, total_cents: 449,
                                 address: "1 Dame Street, Dublin 2",
                                 timezone: DeliverySlots::DEFAULT_ZONE_NAME)
    @bob_order   = Order.create!(user: @bob,   status: Order::CREATED, total_cents: 449,
                                 address: "9 Grafton Street, Dublin 2",
                                 timezone: DeliverySlots::DEFAULT_ZONE_NAME)

    # `kyc_status` polls ONE verification by the broker's request id, so it is
    # the one verb here that cannot be called with no arguments at all.
    @alice_kyc = KycVerificationRequest.create!(request_token: "req-alice-conformance",
                                                user_id: @alice.id,
                                                status: KycVerificationRequest::PENDING)
    @bob_kyc   = KycVerificationRequest.create!(request_token: "req-bob-conformance",
                                                user_id: @bob.id,
                                                status: KycVerificationRequest::PENDING)
  end

  # ── 1. THE ROUTES RESOLVE ───────────────────────────────────────────────
  #
  # Every verb needs a line in `config/routes/kiosk.rb`, and a verb declared
  # without one is a 404 to every caller — something this app's own flow tasks
  # would notice only if one of them happened to call it. This asks the router
  # about all eight at once.
  #
  # Watched fail: delete the `get "/kiosk/delivery_slots"` line and this goes
  # red naming the verb, the method and the path — where `check:shop` would keep
  # passing until it reached that one call.
  test "every declared verb is routed, with the method its kind requires" do
    assert_kiosk_verbs_routed
  end

  # ── 2. A VERB EXECUTES ──────────────────────────────────────────────────
  #
  # With no arguments given, each check runs the verb's OWN `example_params` —
  # the object the descriptor tells an assistant to copy — so this executes the
  # published example as well as the handler.
  test "the read surface executes as an authenticated principal" do
    assert_kiosk_verb_executes :catalog,        as: @alice
    assert_kiosk_verb_executes :delivery_slots, as: @alice
    assert_kiosk_verb_executes :my_orders,      as: @alice
    assert_kiosk_verb_executes :kyc_status,     as: @alice,
                               params: { request_id: @alice_kyc.request_token }
  end

  # ── 3. A QUERY ANSWERS THE SHAPE IT DECLARED ────────────────────────────
  #
  # `output_schema` is the only machine-readable statement of what a call
  # returns, so a descriptor that mis-states it is worse than one that says
  # nothing: the assistant shapes its parse from it and never meets the handler
  # that disagrees. Same validator the engine runs with
  # `validate_responses` on, so this and a running server cannot differ.
  #
  # Watched fail: publish `price_cents` as `Product.format_eur(...)` in the
  # catalog handler and this names the pointer `/0/price_cents` and the type it
  # expected.
  test "catalog answers the shape it publishes" do
    assert_kiosk_answer_matches_declared_schema :catalog, as: @alice
  end

  test "my_orders answers the shape it publishes" do
    assert_kiosk_answer_matches_declared_schema :my_orders, as: @alice
  end

  test "delivery_slots answers the shape it publishes" do
    assert_kiosk_answer_matches_declared_schema :delivery_slots, as: @alice
  end

  test "kyc_status answers the shape it publishes" do
    assert_kiosk_answer_matches_declared_schema :kyc_status, as: @alice,
                                                params: { request_id: @alice_kyc.request_token }
  end

  # ── 4. DATA ACCESS IS SCOPED TO THE PRINCIPAL ───────────────────────────
  #
  # `my_orders` declares no `reach`, which means `principal` — the strongest
  # claim in the descriptor and the one made by saying nothing. The assertion is
  # that no row alice sees reaches bob, and it carries its own positive control:
  # it fails if alice sees nothing, because a verb that answers everybody with
  # nothing would otherwise satisfy it while broken.
  #
  # Watched fail: change `Order.owned_by_current_principal` to `Order.all` and
  # this names the leaked rows.
  test "my_orders hands one shopper nothing belonging to another" do
    assert_kiosk_scoped_to_principal :my_orders, as: @alice, and_not: @bob
  end

  # The same property on the verb where a leak would be worse: `kyc_status`
  # carries the broker's signed attestation once it lands, so a caller who could
  # poll somebody else's request id could lift it. Both principals ask for
  # ALICE's request; bob must be answered nothing.
  test "kyc_status hands one principal nothing belonging to another" do
    assert_kiosk_scoped_to_principal :kyc_status, as: @alice, and_not: @bob,
                                     params: { request_id: @alice_kyc.request_token }
  end
end
