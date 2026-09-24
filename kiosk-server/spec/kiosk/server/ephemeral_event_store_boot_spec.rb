# frozen_string_literal: true

# K-1804 — the refusal, against a REAL booted Rails application in production.
#
# ephemeral_event_store_spec.rb asserts the CONDITION on the engine class. This
# file asserts the consequence: that the engine's `after_initialize` block turns
# that condition into a refused boot, that the topic roster it reads is the one
# the REGISTRY holds after `to_prepare` rebuilt it from `c.handlers`, and that
# neither correct shape is touched by it. Out of process, one boot per scenario;
# see the app's header.

require "open3"

module EphemeralEventStoreBoot
  APP = File.expand_path("../../support/ephemeral_event_store_boot_app.rb", __dir__)

  def self.report(scenario)
    @reports ||= {}
    @reports[scenario] ||= begin
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, APP, scenario)
      # The app reports a refused boot as DATA, on stdout, at exit 0 — a
      # non-zero exit here means the fixture itself broke, which must not be
      # read as "the engine refused".
      unless status.success?
        raise "ephemeral-event-store boot app (#{scenario}) failed (#{status.exitstatus}):\n" \
              "--- stdout ---\n#{stdout}\n--- stderr ---\n#{stderr}"
      end
      JSON.parse(stdout)
    end
  end
end

RSpec.describe "an ephemeral event store in a booted production app" do
  def boot(scenario) = EphemeralEventStoreBoot.report(scenario)

  context "an origin that declares a topic and configures no event store" do
    it "does not come up at all" do
      expect(boot("topic_without_store")["booted"]).to be(false)
    end

    it "refuses with a ConfigurationError, not with whatever raised first" do
      expect(boot("topic_without_store")["error_class"])
        .to eq("Kiosk::Server::Errors::ConfigurationError")
    end

    # The roster is NOT a value the fixture handed the check: the topic is
    # declared on a handler controller, and the registry the block reads is the
    # one `to_prepare` rebuilt from `c.handlers` during this very boot.
    it "names the topic it found in the rebuilt registry" do
      expect(boot("topic_without_store")["message"]).to include("(delivery)")
    end

    it "names the setting the operator has to add" do
      expect(boot("topic_without_store")["message"])
        .to include("c.event_store = Kiosk::Server::EventStores::ActiveRecord.new")
    end
  end

  context "an origin that declares a topic AND a durable store" do
    it "boots — this is what the four topic-declaring demos and the e2e fixture configure" do
      expect(boot("topic_with_store")["booted"]).to be(true)
    end

    it "boots with a topic registered, so the scenario is not passing by being empty" do
      expect(boot("topic_with_store")["topics"]).to eq(%w[delivery])
    end
  end

  # The conditional half. An origin with verbs and no topic never emits, never
  # serves `events` in its catalogue and never advertises an `events_url`; it
  # keeps the in-process default and comes up exactly as it did before.
  context "an origin that declares no topic at all" do
    it "boots" do
      expect(boot("no_topic")["booted"]).to be(true)
    end

    it "boots still holding the in-process default — nothing was made mandatory" do
      expect(boot("no_topic")["topics"]).to eq([])
      expect(boot("no_topic")["store_class"]).to eq("Kiosk::Server::EventStore")
    end
  end
end
