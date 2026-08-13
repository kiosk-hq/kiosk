# frozen_string_literal: true

require "spec_helper"
require_relative "support"

RSpec.describe Kiosk::Redteam::Scenarios::ForgedUserId do
  subject(:scenario) { described_class.new }

  let(:client) { Kiosk::Redteam::Client.new(base_url: BASE_URL) }

  let(:profile) do
    minimal_profile(
      per_user_query: "my_reservations",
      forge_action:   "reserve",
      forge_args:     ->(_client, _a, _b) { { scooter_code: "SK-001" } },
    )
  end

  describe "#call — non-vacuity" do
    context "when the server honours the forged user_id (broken — BREACH)" do
      it "returns blocked: false" do
        stub_registers("a", "b")
        # forge_action by B with user_id=A succeeds and returns "res-forged"
        # Then A's query returns res-forged (forged id was honoured)
        stub_request(:post, "#{BASE_URL}/kiosk/run")
          .with { |req| JSON.parse(req.body)["name"] == "reserve" }
          .to_return(
            status: 200,
            body:   JSON.generate({ "value" => { "id" => "res-forged", "owner" => "user-a" } }),
            headers: { "Content-Type" => "application/json" },
          )
        stub_request(:post, "#{BASE_URL}/kiosk/query")
          .to_return(
            status: 200,
            body:   JSON.generate({ "rows" => [{ "id" => "res-forged" }] }),
            headers: { "Content-Type" => "application/json" },
          )

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(false)
        expect(verdict.skipped).to be(false)
        expect(verdict.detail).to include("user-a")
      end
    end

    context "when the forge response does not contain a recognisable id (indeterminate — BREACH)" do
      it "returns blocked: false rather than silently claiming BLOCKED" do
        stub_registers("a", "b")
        # forge_action returns 200 but body has no 'id' key (e.g. different field name)
        stub_request(:post, "#{BASE_URL}/kiosk/run")
          .with { |req| JSON.parse(req.body)["name"] == "reserve" }
          .to_return(
            status: 200,
            body:   JSON.generate({ "value" => { "unknown_key" => "xyz" } }),
            headers: { "Content-Type" => "application/json" },
          )

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(false)
        expect(verdict.skipped).to be(false)
        expect(verdict.detail).to include("result_id_key")
      end
    end

    context "when the server ignores the forged user_id (correct — BLOCKED)" do
      it "returns blocked: true when forge_action is rejected 403" do
        stub_registers("a", "b")
        # Forge call is rejected outright
        stub_request(:post, "#{BASE_URL}/kiosk/run")
          .with { |req| JSON.parse(req.body)["name"] == "reserve" }
          .to_return(
            status:  403,
            body:    JSON.generate({ "error" => { "code" => "forbidden" } }),
            headers: { "Content-Type" => "application/json" },
          )

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(true)
        expect(verdict.skipped).to be(false)
      end

      it "returns blocked: true when A's query does not contain the forged resource" do
        stub_registers("a", "b")
        stub_request(:post, "#{BASE_URL}/kiosk/run")
          .with { |req| JSON.parse(req.body)["name"] == "reserve" }
          .to_return(
            status: 200,
            body:   JSON.generate({ "value" => { "id" => "res-b-own" } }),
            headers: { "Content-Type" => "application/json" },
          )
        stub_exec_query(rows: [])  # A sees nothing new

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(true)
        expect(verdict.skipped).to be(false)
      end
    end
  end

  # ── K-728 ────────────────────────────────────────────────────────────────
  #
  # "The server caught it" means an auth/authz refusal. A 402 is a toll firing
  # ahead of the handler and says nothing about whether the injected user_id
  # would have been honoured; it used to score BLOCKED.
  describe "#call — the outright rejection must be an auth/authz refusal (K-728)" do
    def stub_forge(status, body)
      stub_registers("a", "b")
      stub_request(:post, "#{BASE_URL}/kiosk/run")
        .with { |req| JSON.parse(req.body)["name"] == "reserve" }
        .to_return(status: status, body: JSON.generate(body),
                   headers: { "Content-Type" => "application/json" })
    end

    it "blocks when the forge call is refused 401 (identity claim rejected)" do
      stub_forge(401, "error" => { "code" => "unauthenticated" })
      expect(scenario.call(client, profile).blocked).to be(true)
    end

    it "does not block when a 402 toll answers instead" do
      stub_forge(402, "error" => { "code" => "pow_required" })
      verdict = scenario.call(client, profile)
      expect(verdict.blocked).to be(false)
      expect(verdict.detail).to include("want status 401/403")
    end
  end

  describe "#call — skip conditions" do
    it "skips when forge_action is nil" do
      p = Kiosk::Redteam::Profile.new(create_owned: ->(_c, _p) { { id: "x" } })
      expect(scenario.call(client, p).detail).to include("SKIP")
    end

    it "skips when forge_args is nil" do
      p = Kiosk::Redteam::Profile.new(
        create_owned: ->(_c, _p) { { id: "x" } },
        forge_action: "reserve",
      )
      expect(scenario.call(client, p).detail).to include("SKIP")
    end
  end
end
