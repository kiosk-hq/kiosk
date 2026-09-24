# frozen_string_literal: true

# K-1804 — the boot refusal for a production origin that declares an event
# topic and leaves the IN-PROCESS event store in place.
#
# The class K-1792 could not close. That row moved four demos onto the durable
# store one file at a time; every one of them had the defect at once and CI was
# green over all of them, because nothing anywhere tied «declares a topic» to
# «sets a durable store» — no default, no refusal, no warning, no check. The
# engine is the only place that reaches an operator who is not us: a check over
# this tree sees our seven demos and nobody else's origin, and a corpus example
# sees only suites that run it.
#
# The condition lives on the engine class rather than inside its
# `after_initialize` block so it can be asserted without booting a production
# Rails app, which is the shape `.shared_spent_store_warning` and
# `.default_role_configuration_error` beside it already use. `topics` is an
# argument rather than a read of the process-global registry, so each example
# states the whole shape of the origin it is describing. That the engine's
# `after_initialize` block turns the condition into a refused boot is proven
# separately, against a real boot, in ephemeral_event_store_boot_spec.rb.
RSpec.describe Kiosk::Server::Engine, ".ephemeral_event_store_error" do
  def error(production: true, topics: %w[delivery])
    described_class.ephemeral_event_store_error(
      config: Kiosk.configuration, production: production, topics: topics,
    )
  end

  # A stand-in for the shipped durable store. The real
  # EventStores::ActiveRecord needs a database connection to do anything; the
  # condition only asks whether the store IS the in-process default, so any
  # object that is not one answers the question.
  let(:durable_store) do
    Class.new do
      def append(_key, _event) = 1
      def since(_key, _id) = []
      def head = 0
      def truncated?(_key, _id) = false
    end.new
  end

  context "when a topic is declared and the store is the in-process default" do
    it "refuses in production" do
      expect(error).to include("`event_store` is the IN-PROCESS default")
    end

    it "names the topics, so the operator knows what is affected" do
      expect(error(topics: %w[todo delivery])).to include("(delivery, todo)")
    end

    # The whole reason this is a refusal and not a log line: the operator
    # cannot discover it by watching their own system.
    it "says WHY it matters — the loss is silent, and it is total for a subscription" do
      expect(error).to include("no error, no metric and no log line")
      expect(error).to include("DELIVERED BY the cursor and has no other")
      expect(error).to include("24 hours of events per identity")
    end

    it "names the shipped durable store so the fix needs no search" do
      expect(error).to include("c.event_store = Kiosk::Server::EventStores::ActiveRecord.new")
    end

    # The in-process store is the CORRECT store for the suite and for a
    # one-process development boot, which is what it exists for.
    it "stays quiet outside production" do
      expect(error(production: false)).to be_nil
    end

    it "stays quiet once a durable store is configured" do
      Kiosk.configure { |c| c.event_store = durable_store }
      expect(error).to be_nil
    end
  end

  # An origin that declares no topic never emits, never serves `events` in its
  # catalogue and never advertises an `events_url`. Its store is an object
  # nothing calls, and refusing to boot it would be a false accusation — the
  # exact failure `.shared_spent_store_warning` takes care to avoid.
  it "does NOT refuse an origin that declares no topic at all" do
    expect(error(topics: [])).to be_nil
  end

  it "treats a whitespace-only topic name as no topic, rather than as a declaration" do
    expect(error(topics: ["", "  "])).to be_nil
  end
end
