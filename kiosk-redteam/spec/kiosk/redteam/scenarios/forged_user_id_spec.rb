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
        # create_owned for A
        stub_exec_run(status: 200, body: { "value" => { "id" => "res-a" } })

        # forge_action by B with user_id=A succeeds and returns "res-forged"
        # Then A's query returns res-forged (forged id was honoured)
        stub_request(:post, "#{BASE_URL}/kiosk/exec")
          .with { |req|
            body = JSON.parse(req.body)
            body["command"] == "run" && body.dig("body", "name") == "reserve"
          }
          .to_return(
            status: 200,
            body:   JSON.generate({ "value" => { "id" => "res-forged", "owner" => "user-a" } }),
            headers: { "Content-Type" => "application/json" },
          )
        stub_request(:post, "#{BASE_URL}/kiosk/exec")
          .with { |req| JSON.parse(req.body)["command"] == "query" }
          .to_return(
            status: 200,
            body:   JSON.generate({ "rows" => [{ "id" => "res-forged" }] }),
            headers: { "Content-Type" => "application/json" },
          )

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(false)
        expect(verdict.detail).to include("user-a")
      end
    end

    context "when the server ignores the forged user_id (correct — BLOCKED)" do
      it "returns blocked: true when forge_action is rejected 403" do
        stub_registers("a", "b")
        stub_exec_run(status: 200, body: { "value" => { "id" => "res-a" } })
        # Forge call is rejected outright
        stub_request(:post, "#{BASE_URL}/kiosk/exec")
          .with { |req|
            body = JSON.parse(req.body)
            body["command"] == "run" && body.dig("body", "name") == "reserve"
          }
          .to_return(
            status:  403,
            body:    JSON.generate({ "error" => { "code" => "forbidden" } }),
            headers: { "Content-Type" => "application/json" },
          )

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(true)
      end

      it "returns blocked: true when A's query does not contain the forged resource" do
        stub_registers("a", "b")
        stub_exec_run(status: 200, body: { "value" => { "id" => "res-a" } })
        stub_request(:post, "#{BASE_URL}/kiosk/exec")
          .with { |req|
            body = JSON.parse(req.body)
            body["command"] == "run" && body.dig("body", "name") == "reserve"
          }
          .to_return(
            status: 200,
            body:   JSON.generate({ "value" => { "id" => "res-b-own" } }),
            headers: { "Content-Type" => "application/json" },
          )
        stub_exec_query(rows: [])  # A sees nothing new

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(true)
      end
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
