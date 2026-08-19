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

  # The attack is `POST /kiosk/reserve` under B's token with `user_id: A` merged
  # into the body, then `GET /kiosk/my_reservations` under A's token.
  #
  # ── The action body these stubs answer with ──────────────────────────────
  # ForgedUserId#extract_id reads `body["value"][result_id_key]`. A 0.4 action
  # answers its OWN object with no wrapper (Kiosk::Server::Result#to_payload),
  # so the `value` nesting below is the shape the gem can currently read rather
  # than the shape the shipped verbs send. The two pending examples at the
  # bottom of this file pin what a real 0.4 origin answers.
  def forge_result(id)
    { "value" => { "id" => id } }
  end

  describe "#call — non-vacuity" do
    it "puts the forged user_id on the wire as a plain argument, with no `name` field" do
      stub_registers("a", "b")
      captured = nil
      stub_request(:post, verb_url("reserve"))
        .with { |req| captured = req; true }
        .to_return(problem_return("forbidden"))

      scenario.call(client, profile)

      expect(captured.uri.path).to eq("/kiosk/reserve")
      expect(captured.headers["Authorization"]).to eq("Bearer tok-b")   # B calls it
      body = JSON.parse(captured.body)
      expect(body).to eq("scooter_code" => "SK-001", "user_id" => "user-a")
      expect(body).not_to have_key("name")
    end

    context "when the server honours the forged user_id (broken — BREACH)" do
      it "returns blocked: false" do
        stub_registers("a", "b")
        # forge_action by B with user_id=A succeeds and returns "res-forged";
        # then A's query returns res-forged (the forged id WAS honoured).
        stub_action("reserve", status: 200, body: forge_result("res-forged"))
        stub_query("my_reservations", rows: [{ "id" => "res-forged" }])

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(false)
        expect(verdict.skipped).to be(false)
        expect(verdict.detail).to include("user-a")
      end
    end

    context "when the forge response does not contain a recognisable id (indeterminate — BREACH)" do
      it "returns blocked: false rather than silently claiming BLOCKED" do
        stub_registers("a", "b")
        # 200, but nothing under result_id_key — ownership cannot be confirmed.
        stub_action("reserve", status: 200, body: { "unknown_key" => "xyz" })

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(false)
        expect(verdict.skipped).to be(false)
        expect(verdict.detail).to include("result_id_key")
      end
    end

    context "when the server ignores the forged user_id (correct — BLOCKED)" do
      it "returns blocked: true when forge_action is rejected 403" do
        stub_registers("a", "b")
        stub_action("reserve", status: 403, code: "forbidden")

        verdict = scenario.call(client, profile)

        expect(verdict.blocked).to be(true)
        expect(verdict.skipped).to be(false)
      end

      it "returns blocked: true when A's query does not contain the forged resource" do
        stub_registers("a", "b")
        stub_action("reserve", status: 200, body: forge_result("res-b-own"))
        stub_query("my_reservations", rows: [])  # A sees nothing new

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
    def stub_forge(status, code)
      stub_registers("a", "b")
      stub_action("reserve", status: status, code: code)
    end

    it "blocks when the forge call is refused 401 (identity claim rejected)" do
      stub_forge(401, "unauthenticated")
      expect(scenario.call(client, profile).blocked).to be(true)
    end

    # K-736: a 402 answered nothing at all — the toll fired ahead of the
    # handler, so neither the outright-rejection branch nor the ownership
    # check below it learned anything. Say could-not-test and name the code.
    it "does not block when a 402 toll answers instead" do
      stub_forge(402, "pow_required")
      verdict = scenario.call(client, profile)
      expect(verdict.blocked).to be(false)
      expect(verdict.skipped).to be(false)
      expect(verdict.detail).to include("COULD NOT TEST")
      expect(verdict.detail).to include("the forged-user_id reserve call")
      expect(verdict.detail).to include('"pow_required"')
    end

    it "does not block when the forge call comes back 402 payment_setup_required" do
      stub_forge(402, "payment_setup_required")
      verdict = scenario.call(client, profile)
      expect(verdict.blocked).to be(false)
      expect(verdict.detail).to include('"payment_setup_required"')
    end
  end

  # ── What a real 0.4 origin answers, and what this scenario makes of it ───
  describe "#call — against the shipped 0.4 wire" do
    # An action's payload reaches the wire VERBATIM, so skooti's `reserve`
    # answers {reservation_id, scooter_code, price_per_min_cents, currency,
    # pay_hint} — a bare object. extract_id looks under `body["value"]`, the
    # envelope the cutover deleted; reading only that shape would find nothing
    # on ANY real origin, and every run of this scenario would end "cannot
    # confirm ownership was enforced" — an indeterminate verdict for a wire
    # that answered perfectly clearly.
    it "reads the resource id out of the action's own object" do
      stub_registers("a", "b")
      stub_action("reserve", status: 200,
                  body: { "reservation_id" => "res-forged", "scooter_code" => "SK-001" })
      stub_query("my_reservations", rows: [{ "reservation_id" => "res-forged" }])
      p = minimal_profile(per_user_query: "my_reservations", row_id_key: "reservation_id",
                          result_id_key: "reservation_id", forge_action: "reserve",
                          forge_args: ->(_c, _a, _b) { { scooter_code: "SK-001" } })

      verdict = scenario.call(client, p)

      # A's rows DO carry the resource: the forged user_id was honoured.
      expect(verdict.blocked).to be(false)
      expect(verdict.detail).to include("res-forged")
    end

    # Every shipped 0.4 verb declares `additionalProperties: false` and
    # RequestValidation runs on every call, so an undeclared `user_id` is now
    # refused by NAME with a typed 400 instead of being silently ignored. That
    # is the strongest possible evidence the forged argument did not take
    # effect — but `bad_request` is excluded from BLOCKED_ERROR_CODES (a
    # validation error is not an auth gate), so the scenario falls through to
    # the ownership check would find no id and report a BREACH against a
    # provider that did exactly the right thing. The branch that fixes it lives
    # in the SCENARIO, not in `blocked?`, because what makes this particular
    # 400 evidence is that the refusal NAMES the property we injected — which
    # a generic predicate has no way to check.
    it "scores the typed 400 that refuses the forged property as BLOCKED" do
      stub_registers("a", "b")
      stub_request(:post, verb_url("reserve")).to_return(
        problem_return(
          "bad_request",
          detail: "reserve: object property at `/user_id` is a disallowed additional property",
          hint:   "GET <endpoint>/schema publishes this verb's input_schema; " \
                  "the arguments must satisfy it.",
        ),
      )

      verdict = scenario.call(client, profile)

      expect(verdict.blocked).to be(true)
      expect(verdict.status).to eq(400)
      expect(verdict.detail).to include("user_id")
    end

    # …and the branch is NOT "any 400 is a pass". A validation failure about
    # something else is an ordinary bad request: the injected argument may
    # still have been accepted, so the scenario must carry on to the ownership
    # check rather than scoring a block it has not earned.
    it "does NOT score a 400 that refuses some OTHER property" do
      stub_registers("a", "b")
      stub_request(:post, verb_url("reserve")).to_return(
        problem_return(
          "bad_request",
          detail: "reserve: object at root is missing required properties: scooter_code",
        ),
      )

      verdict = scenario.call(client, profile)

      expect(verdict.blocked).to be(false)
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
