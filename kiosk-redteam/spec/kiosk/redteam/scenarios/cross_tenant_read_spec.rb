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

  # Both legs are `GET /kiosk/my_orders` — the query name is the PATH SEGMENT
  # and neither leg carries arguments, so the two are one endpoint answered
  # twice: A's control query first, then B's attack query.
  #
  # (minimal_profile's create_owned is a plain lambda, so nothing here calls an
  # action; the only wire traffic is register + these two queries.)
  def stub_control_then_attack(control_rows:, attack_rows: nil, attack_status: 200,
                               attack_code: nil, control_status: 200)
    stub_request(:get, verb_url("my_orders")).to_return(
      wire_return(status: control_status, body: control_rows),
      wire_return(status: attack_status, body: attack_rows || [], code: attack_code),
    )
  end

  describe "#call — non-vacuity" do
    context "when the server leaks A's row to B (broken — BREACH)" do
      it "returns blocked: false" do
        stub_registers("a", "b")
        # B's query leaks A's row — broken server
        stub_control_then_attack(control_rows: [{ "id" => "res-1", "user_id" => "user-a" }],
                                 attack_rows:  [{ "id" => "res-1", "user_id" => "user-a" }])

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(false)
        expect(verdict.detail).to include("res-1")
      end
    end

    context "when the server correctly isolates rows (correct — BLOCKED)" do
      it "returns blocked: true" do
        stub_registers("a", "b")
        # A sees A's row; B's query returns B's own rows only — res-1 absent.
        stub_control_then_attack(control_rows: [{ "id" => "res-1", "user_id" => "user-a" }],
                                 attack_rows:  [{ "id" => "res-99", "user_id" => "user-b" }])

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(true)
        expect(verdict.status).to eq(200)
      end
    end

    context "when B's query returns empty rows and the control holds" do
      it "returns blocked: true" do
        stub_registers("a", "b")
        stub_control_then_attack(control_rows: [{ "id" => "res-1" }], attack_rows: [])

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(true)
      end
    end
  end

  # ── K-729 ────────────────────────────────────────────────────────────────
  #
  # This block OVERTURNS the spec that used to sit here — "when B's query
  # returns empty rows { returns blocked: true }" with no control query stubbed
  # at all, which enshrined exactly the vacuity below. Empty rows are still a
  # pass, but only once A's own query has demonstrated that this query returns
  # this key for its owner.
  describe "#call — the empty answer must be earned (K-729)" do
    context "when the provider answers EVERY query with [] (no isolation logic)" do
      it "fails the control instead of scoring a pass" do
        stub_registers("a", "b")
        stub_query("my_orders", rows: [])   # both the control and the attack answer []

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(false)
        expect(verdict.detail).to include("CONTROL FAILED")
      end
    end

    context "when row_id_key names no field in the rows (a real leak reads as clean)" do
      it "fails the control instead of scoring a pass" do
        stub_registers("a", "b")
        # Both A and B see A's row — a total isolation failure — but under a key
        # the profile does not name, so the leak check can never fire.
        stub_query("my_orders", rows: [{ "id" => "res-1" }])
        mismatched = minimal_profile(per_user_query: "my_orders", row_id_key: "order_id")

        verdict = scenario.call(client, mismatched)

        expect(verdict.blocked).to be(false)
        expect(verdict.detail).to include("CONTROL FAILED")
        expect(verdict.detail).to include("order_id")
      end
    end

    context "when A's own query is not answered at all" do
      it "fails the control" do
        stub_registers("a", "b")
        stub_query("my_orders", status: 404)

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(false)
        expect(verdict.detail).to include("CONTROL FAILED")
        expect(verdict.status).to eq(404)
      end
    end
  end

  # A non-2xx on B's query is not isolation — and a 5xx counting as blocked
  # broke the gem's own "a crash can never mask a breach" invariant.
  describe "#call — B's query must be ANSWERED (K-729)" do
    [
      [500, "internal_error", "a crash"],
      [502, "internal_error", "a bad gateway"],
      [404, "not_found",      "a query name that never resolved"],
      [402, "pow_required",   "a toll that fired before any policy ran"],
      [403, "forbidden",      "a query refused outright to its own principal"],
    ].each do |status, code, why|
      it "returns blocked: false when B's query answers #{status} (#{why})" do
        stub_registers("a", "b")
        stub_control_then_attack(
          control_rows:  [{ "id" => "res-1" }],
          attack_status: status,
          attack_code:   code,
        )

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(false)
        expect(verdict.status).to eq(status)
        expect(verdict.detail).to include("not answered")
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
