# frozen_string_literal: true

require "test_helper"

# THE STRIPE RETURN PAGE, WHICH IS ALSO THE `payment_setup` EMITTER.
#
# This page is the operator-side half of a topic: the human saves a card on
# Stripe's hosted page, Stripe redirects their browser here, and this is the
# instant the operator learns readiness. Before it, an assistant discovered the
# same fact by calling `payment_setup` again and again — roughly 28 times over
# five minutes by the skill's cadence, each one a round trip to a third party.
#
# WHY IT NEEDS A TEST AT ALL, stated because the answer is not «coverage»: the
# emitting method RESCUES EVERYTHING AND LOGS AT WARN, deliberately, because a
# Stripe hiccup must not turn «your card is saved» into an error page for a
# human. That rescue is also a gag: a renamed constant, a changed signature or
# a wrong keyword inside it can never redden a gate, and the page would go on
# rendering perfectly while the assistant it is supposed to wake heard nothing.
# These examples are what holds the inside of that rescue.
class PaymentReturnTest < ActionDispatch::IntegrationTest
  STRIPE_CUSTOMER = "cus_test_return_page"
  SESSION_ID      = "cs_test_return_page"

  # A FRESH STORE PER EXAMPLE, and the assertions read it rather than a hook
  # written for them. `emit` appends to whatever `c.event_store` is, so reading
  # it back is reading the real seam — a test double in its place would prove
  # only that a double was called.
  setup do
    @store = Kiosk::Server::EventStore.new
    @previous_store = Kiosk.configuration.event_store
    Kiosk.configure { |c| c.event_store = @store }
  end

  teardown do
    Kiosk.configure { |c| c.event_store = @previous_store }
  end

  # The page ALWAYS renders. Every arm below asserts that too, because the
  # human in front of it is owed an answer whatever the operator's own
  # bookkeeping is doing.
  test "renders the confirmation page with no session_id at all" do
    get "/payment/return"

    assert_response :success
    assert_match "Card saved", response.body
    assert_equal 0, @store.head
  end

  test "renders, and emits NOTHING, when the session names no customer we know" do
    with_session(customer: "cus_nobody_has_this") do
      get "/payment/return", params: { session_id: SESSION_ID }
    end

    assert_response :success
    assert_equal 0, @store.head, "a customer this operator never saved must address no principal"
  end

  # THE POINT OF THE WHOLE PAGE.
  test "emits payment_setup to the principal the session's customer belongs to" do
    user_id = seed_customer!
    with_session(customer: STRIPE_CUSTOMER) do
      with_setup_required(false) do
        get "/payment/return", params: { session_id: SESSION_ID }
      end
    end

    assert_response :success
    event = @store.since(user_id, 0).first
    refute_nil event, "the return page must push payment_setup once readiness is confirmed"
    assert_equal "payment_setup", event["topic"]
    assert_equal user_id, event["subject"]
    assert_equal({ "status" => "ready" }, event["data"])
  end

  # ARRIVING HERE IS NOT EVIDENCE OF A SAVED CARD. It means a browser followed
  # a link — the url is unauthenticated and anyone may request it in any order.
  # So readiness is RE-DERIVED from the same predicate the verb answers, and a
  # page that skipped that would push `ready` to an assistant that then fails
  # its very next `pay`.
  test "emits NOTHING when the provider still says setup is required" do
    seed_customer!
    with_session(customer: STRIPE_CUSTOMER) do
      with_setup_required(true) do
        get "/payment/return", params: { session_id: SESSION_ID }
      end
    end

    assert_response :success
    assert_equal 0, @store.head, "the redirect is not the evidence; setup_required? is"
  end

  # The rescue is deliberate and this is what keeps it honest: it must swallow
  # the failure for the HUMAN without swallowing it for the assertion above.
  test "still renders when Stripe cannot be reached" do
    with_stub(::Stripe::Checkout::Session, :retrieve,
              ->(_id) { raise ::Stripe::APIError, "down" }) do
      get "/payment/return", params: { session_id: SESSION_ID }
    end

    assert_response :success
    assert_match "Card saved", response.body
    assert_equal 0, @store.head
  end

  # THE PLACEHOLDER IS WHAT MAKES ANY OF THE ABOVE POSSIBLE. Without it the
  # return url is one constant for every principal, the page cannot tell whose
  # human came back, and the emit has nobody to address — a whole topic that
  # renders correctly and reaches no one.
  test "the return url this operator hands Stripe carries the session-id placeholder" do
    adapter = Kiosk.configuration.payment_provider.instance_variable_get(:@provider)
    url     = adapter.send(:resolved_return_url)

    assert_includes url, "/payment/return"
    assert_includes url, "session_id={CHECKOUT_SESSION_ID}",
                    "without the placeholder the return page is anonymous and the topic reaches nobody"
  end

  private

  def seed_customer!
    user = User.create!(email: "return-page-#{SecureRandom.hex(4)}@example.test",
                        password: SecureRandom.hex(16))
    StripeCustomer.create!(user_id: user.id, customer_id: STRIPE_CUSTOMER)
    user.id
  end

  # SAVE AND RESTORE, WRITTEN OUT. Minitest 6 ships no `minitest/mock`, so
  # there is no `stub` to lean on — and a bare `define_singleton_method` would
  # patch the constant for the rest of the process, making every later example
  # in this suite depend on the order it happened to run in. The `ensure` is
  # the whole point of the helper.
  def with_stub(object, name, replacement)
    owned    = object.singleton_class.method_defined?(name)
    original = object.method(name) if owned
    object.define_singleton_method(name, replacement)
    yield
  ensure
    object.singleton_class.send(:remove_method, name)
    object.define_singleton_method(name, original) if original
  end

  def with_session(customer:, &block)
    with_stub(::Stripe::Checkout::Session, :retrieve,
              ->(_id) { Struct.new(:customer).new(customer) }, &block)
  end

  def with_setup_required(value, &block)
    with_stub(Kiosk.configuration.payment_provider, :setup_required?,
              ->(user_id:) { value }, &block)
  end
end
