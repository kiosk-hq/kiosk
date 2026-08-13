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
      expect(scenario.verdict_from(response(402)).blocked).to be(true)
      expect(scenario.verdict_from(response(403)).blocked).to be(true)
    end

    it "does not block a 200" do
      expect(scenario.verdict_from(response(200), detail: "leaked").blocked).to be(false)
    end

    it "does not block a 500" do
      expect(scenario.verdict_from(response(500)).blocked).to be(false)
    end
  end

  describe "#verdict_from with expect:" do
    it "blocks when the status is the one demanded" do
      v = scenario.verdict_from(response(403), expect: 403)
      expect(v.blocked).to be(true)
      expect(v.detail).to eq("")
    end

    it "accepts any of several demanded statuses" do
      expect(scenario.verdict_from(response(402), expect: [402, 403]).blocked).to be(true)
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
