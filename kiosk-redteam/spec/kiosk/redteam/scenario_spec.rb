# frozen_string_literal: true

require "spec_helper"

# The Scenario base class's verdict machinery — the piece every scenario in the
# library leans on, and until K-728 the piece that could not express "this gate,
# not some other gate".
RSpec.describe Kiosk::Redteam::Scenario do
  # A scenario that does nothing but expose the protected helpers.
  let(:scenario) do
    Class.new(described_class) do
      def initialize
        super(name: "Probe", category: "test", description: "exposes the helpers")
      end

      public :verdict_from, :skip_verdict, :error_code, :rows_from
    end.new
  end

  def response(status, body = {})
    Kiosk::Redteam::Response.new(status:, body:)
  end

  describe "#verdict_from without expect/expect_code (permissive)" do
    it "blocks on any of the canonical statuses" do
      expect(scenario.verdict_from(response(401)).blocked).to be(true)
      expect(scenario.verdict_from(response(403)).blocked).to be(true)
    end

    it "does not block a 200" do
      expect(scenario.verdict_from(response(200), detail: "leaked").blocked).to be(false)
    end

    it "does not block a 500" do
      expect(scenario.verdict_from(response(500)).blocked).to be(false)
    end
  end

  # ── K-736 ────────────────────────────────────────────────────────────────
  #
  # The permissive path delegated to `blocked?`, which said true for a bare
  # 402 — so a tolled verb printed BLOCKED for an attack the harness never
  # mounted (it solves PoW only at registration). All three codes kiosk-server
  # maps onto 402 now produce the same could-not-test verdict, which names
  # which one answered so the line is not read as a provider hole.
  describe "#verdict_from — HTTP 402 is never a pass on the permissive path (K-736)" do
    {
      "pow_required"           => "a toll was DEMANDED",
      "payment_setup_required" => "no payment instrument on file",
      "payment_failed"         => "the payment rail declined",
    }.each do |code, phrase|
      it "does not block a 402 #{code}, and says which one answered" do
        v = scenario.verdict_from(response(402, "error" => { "code" => code }),
                                  detail: "the gated action succeeded")
        expect(v.blocked).to be(false)
        expect(v.skipped).to be(false)
        expect(v.status).to eq(402)
        expect(v.detail).to include("COULD NOT TEST")
        expect(v.detail).to include(code.inspect)
        expect(v.detail).to include(phrase)
      end
    end

    it "does not block a bare 402 that names no code" do
      v = scenario.verdict_from(response(402))
      expect(v.blocked).to be(false)
      expect(v.detail).to include("named none of them")
    end

    # A skip would be invisible to Runner#all_blocked?, so a consumer without
    # the demos' expected-skip assertion would go green while the scenario had
    # quietly stopped testing. The stall must fail the battery.
    it "is a breach-shaped verdict, not a skip — the battery cannot go green on it" do
      v = scenario.verdict_from(response(402, "error" => { "code" => "pow_required" }))
      expect(v.skipped).to be(false)
      expect(v.blocked).to be(false)
    end

    it "still blocks a 200 envelope carrying a real denial code" do
      expect(scenario.verdict_from(response(200, "error" => { "code" => "forbidden" })).blocked).to be(true)
    end
  end

  describe "#verdict_from with expect:" do
    it "blocks when the status is the one demanded" do
      v = scenario.verdict_from(response(403), expect: 403)
      expect(v.blocked).to be(true)
      expect(v.detail).to eq("")
    end

    it "accepts any of several demanded statuses" do
      expect(scenario.verdict_from(response(401), expect: [401, 403]).blocked).to be(true)
    end

    # K-736: `expect: 402` demands nothing on its own — three codes ride that
    # status and two of them are not refusals. Naming it costs an expect_code.
    it "refuses a 402 the caller demanded by status alone" do
      v = scenario.verdict_from(response(402, "error" => { "code" => "pow_required" }), expect: [402, 403])
      expect(v.blocked).to be(false)
      expect(v.detail).to include("HTTP 402 is conclusive only with an explicit expect_code")
      expect(v.detail).to include("pow_required/payment_setup_required/payment_failed")
    end

    it "accepts a 402 whose code the caller named" do
      v = scenario.verdict_from(response(402, "error" => { "code" => "payment_failed" }),
                                expect: [402, 403], expect_code: %w[payment_failed forbidden])
      expect(v.blocked).to be(true)
      expect(v.detail).to eq("")
    end

    it "still refuses a named 402 whose code is one of the other two" do
      v = scenario.verdict_from(response(402, "error" => { "code" => "pow_required" }),
                                expect: 402, expect_code: "payment_failed")
      expect(v.blocked).to be(false)
      expect(v.detail).to include('want error.code "payment_failed"')
    end

    # The headline: a refusal from an UNRELATED gate is no longer a pass.
    it "does NOT block a 401 when the scenario demanded 403" do
      v = scenario.verdict_from(response(401), expect: 403, detail: "ownership gate")
      expect(v.blocked).to be(false)
      expect(v.detail).to include("ownership gate")
      expect(v.detail).to include("want status 403")
      expect(v.detail).to include("got HTTP 401")
    end

    it "does NOT block a 402 when the scenario demanded 403" do
      expect(scenario.verdict_from(response(402), expect: 403).blocked).to be(false)
    end

    it "does NOT block a 404 (a mis-routed path is not a gate)" do
      v = scenario.verdict_from(response(404, "error" => { "code" => "not_found" }), expect: 403)
      expect(v.blocked).to be(false)
      expect(v.detail).to include("not_found")
    end

    it "does NOT block a 500 even if 500 were demanded (5xx is never a block)" do
      v = scenario.verdict_from(response(500), expect: 500)
      expect(v.blocked).to be(false)
      expect(v.detail).to include("5xx is never a block")
    end

    it "reports the status on the verdict either way" do
      expect(scenario.verdict_from(response(409), expect: 403).status).to eq(409)
      expect(scenario.verdict_from(response(403), expect: 403).status).to eq(403)
    end
  end

  describe "#verdict_from with expect_code:" do
    it "blocks when status AND code both match" do
      body = { "error" => { "code" => "forbidden" } }
      expect(scenario.verdict_from(response(403, body), expect: 403, expect_code: "forbidden").blocked).to be(true)
    end

    it "accepts any of several demanded codes" do
      body = { "error" => { "code" => "rls_denied" } }
      v = scenario.verdict_from(response(403, body), expect: 403, expect_code: %w[forbidden rls_denied])
      expect(v.blocked).to be(true)
    end

    it "does NOT block when the status matches but the code does not" do
      body = { "error" => { "code" => "kyc_required" } }
      v = scenario.verdict_from(response(403, body), expect: 403, expect_code: "forbidden")
      expect(v.blocked).to be(false)
      expect(v.detail).to include('want error.code "forbidden"')
    end

    it "does NOT block when there is no error envelope at all" do
      v = scenario.verdict_from(response(403, {}), expect: 403, expect_code: "forbidden")
      expect(v.blocked).to be(false)
      expect(v.detail).to include("code=nil")
    end

    it "does NOT block when error is a bare String rather than an envelope" do
      v = scenario.verdict_from(response(403, "error" => "nope"), expect: 403, expect_code: "forbidden")
      expect(v.blocked).to be(false)
    end

    it "can demand a code without pinning the status" do
      body = { "error" => { "code" => "forbidden" } }
      expect(scenario.verdict_from(response(200, body), expect_code: "forbidden").blocked).to be(true)
      expect(scenario.verdict_from(response(200, {}), expect_code: "forbidden").blocked).to be(false)
    end
  end

  describe "#error_code" do
    it "reads body.error.code" do
      expect(scenario.error_code(response(403, "error" => { "code" => "forbidden" }))).to eq("forbidden")
    end

    it "answers nil for a String error, a non-Hash body, and an absent envelope" do
      expect(scenario.error_code(response(403, "error" => "plain"))).to be_nil
      expect(scenario.error_code(response(403, []))).to be_nil
      expect(scenario.error_code(response(403, {}))).to be_nil
    end
  end

  describe "#skip_verdict" do
    # The docstring claimed `blocked: true` for years after this stopped being
    # true (K-733); pin the shape so prose and code cannot drift apart again.
    it "is a third state, not a pass" do
      v = scenario.skip_verdict("no per_user_query")
      expect(v.skipped).to be(true)
      expect(v.blocked).to be(false)
      expect(v.status).to eq(0)
      expect(v.detail).to eq("SKIP — no per_user_query")
    end
  end
end
