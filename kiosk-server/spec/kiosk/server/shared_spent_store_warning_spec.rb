# frozen_string_literal: true

# K-752 — the boot warning for a production origin still on the IN-PROCESS
# spent store.
#
# Phil decided option C (2026-08-19): WARN, never refuse. A fail-closed boot
# was rejected because it turns a routine `WEB_CONCURRENCY` 1→2 into an outage
# and, decisively, because a process-count check cannot see the case that
# matters at all — on separate machines every process boots with a count of
# one while the shared-store requirement is violated exactly as hard.
#
# So the condition here carries NO process-count heuristic, and these examples
# pin that: nothing in this file reads `WEB_CONCURRENCY`, and the warning fires
# on a single-process production origin too, because that origin may be one of
# many. What it must NOT do is cry wolf at an origin that issues no proofs at
# all — an unread warning is bad, an unread FALSE warning is worse.
#
# The condition lives on the engine class rather than inside its
# `after_initialize` block precisely so it can be asserted without booting a
# production Rails app; the block is three lines that call it.
RSpec.describe Kiosk::Server::Engine, ".shared_spent_store_warning" do
  def warning(production: true)
    described_class.shared_spent_store_warning(config: Kiosk.configuration, production: production)
  end

  # A stand-in for the shipped shared store. The real
  # PowSpentStores::ActiveRecord needs a database connection to do anything;
  # the predicate only asks whether the store IS the in-process default, so any
  # object that is not one answers the question.
  let(:shared_store) do
    Class.new do
      def claim(_id, _exp) = true
      def release(_id) = nil
    end.new
  end

  context "when PoW is enabled and the store is the in-process default" do
    before { Kiosk.configure { |c| c.registration_pow_count = 1 } }

    it "warns in production" do
      expect(warning).to include("pow_spent_store is the IN-PROCESS default")
    end

    # The whole reason prose is the mitigation and the log line is not: the
    # operator cannot discover this by observing their own system.
    it "says WHY it matters — the replay is silent, not merely wrong" do
      expect(warning).to include("no error, no metric")
      expect(warning).to include("once PER PROCESS")
    end

    it "names the shipped shared store so the fix needs no search" do
      expect(warning).to include("Kiosk::Server::PowSpentStores::ActiveRecord.new")
    end

    it "stays quiet outside production" do
      expect(warning(production: false)).to be_nil
    end

    it "stays quiet once a shared store is configured" do
      Kiosk.configure { |c| c.pow_spent_store = shared_store }
      expect(warning).to be_nil
    end
  end

  it "warns when the toll gate is on (reputation_policy), not only registration PoW" do
    Kiosk.configure { |c| c.reputation_policy = Object.new }
    expect(warning).to include("pow_spent_store is the IN-PROCESS default")
  end

  # An origin with no toll and open registration never issues a challenge, so
  # its spent store is never written to. Warning it would be false, and a false
  # production warning is exactly how the true ones stop being read.
  it "does NOT warn when this origin issues no proofs at all" do
    expect(Kiosk.configuration.registration_pow_count).to eq(0)
    expect(Kiosk.configuration.reputation_policy).to be_nil
    expect(warning).to be_nil
  end
end
