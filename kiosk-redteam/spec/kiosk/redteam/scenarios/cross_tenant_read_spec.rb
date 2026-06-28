# frozen_string_literal: true

require "spec_helper"
require_relative "support"

RSpec.describe Kiosk::Redteam::Scenarios::CrossTenantRead do
  subject(:scenario) { described_class.new }

  let(:client) { Kiosk::Redteam::Client.new(base_url: BASE_URL) }

  # Profile with per_user_query and create_owned
  let(:profile) do
    minimal_profile(
      per_user_query: "my_orders",
      row_id_key:     "id",
    )
  end

  describe "#call — non-vacuity" do
    context "when the server leaks A's row to B (broken — BREACH)" do
      it "returns blocked: false" do
        stub_registers("a", "b")
        # create_owned calls run → return owned ref with id "res-1"
        stub_exec_run(status: 200, body: { "value" => { "id" => "res-1" } })
        # B's query leaks A's row — broken server
        stub_exec_query(rows: [{ "id" => "res-1", "user_id" => "user-a" }])

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(false)
        expect(verdict.detail).to include("res-1")
      end
    end

    context "when the server correctly isolates rows (correct — BLOCKED)" do
      it "returns blocked: true" do
        stub_registers("a", "b")
        stub_exec_run(status: 200, body: { "value" => { "id" => "res-1" } })
        # B's query returns B's own rows only — res-1 is NOT present
        stub_exec_query(rows: [{ "id" => "res-99", "user_id" => "user-b" }])

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(true)
      end
    end

    context "when B's query returns empty rows" do
      it "returns blocked: true" do
        stub_registers("a", "b")
        stub_exec_run(status: 200, body: { "value" => { "id" => "res-1" } })
        stub_exec_query(rows: [])

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(true)
      end
    end
  end

  describe "#call — skip conditions" do
    it "skips when per_user_query is nil" do
      profile_no_query = Kiosk::Redteam::Profile.new(create_owned: ->(_c, _p) { { id: "x" } })
      verdict = scenario.call(client, profile_no_query)
      expect(verdict.skipped).to be(true)
      expect(verdict.blocked).to be(false)
      expect(verdict.detail).to include("SKIP")
    end

    it "skips when create_owned is nil" do
      profile_no_create = Kiosk::Redteam::Profile.new(per_user_query: "my_orders")
      verdict = scenario.call(client, profile_no_create)
      expect(verdict.skipped).to be(true)
      expect(verdict.blocked).to be(false)
      expect(verdict.detail).to include("SKIP")
    end
  end
end
