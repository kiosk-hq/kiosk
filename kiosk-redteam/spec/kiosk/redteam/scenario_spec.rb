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
        v = scenario.verdict_from(response(402, problem(code)),
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
      v = scenario.verdict_from(response(402, problem("pow_required")))
      expect(v.skipped).to be(false)
      expect(v.blocked).to be(false)
    end

    it "still blocks a 200 envelope carrying a real denial code" do
      expect(scenario.verdict_from(response(200, problem("forbidden", status: 200))).blocked).to be(true)
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
      v = scenario.verdict_from(response(402, problem("pow_required")), expect: [402, 403])
      expect(v.blocked).to be(false)
      expect(v.detail).to include("HTTP 402 is conclusive only with an explicit expect_code")
      expect(v.detail).to include("pow_required/payment_setup_required/payment_failed")
    end

    it "accepts a 402 whose code the caller named" do
      v = scenario.verdict_from(response(402, problem("payment_failed")),
                                expect: [402, 403], expect_code: %w[payment_failed forbidden])
      expect(v.blocked).to be(true)
      expect(v.detail).to eq("")
    end

    it "still refuses a named 402 whose code is one of the other two" do
      v = scenario.verdict_from(response(402, problem("pow_required")),
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
      v = scenario.verdict_from(response(404, problem("not_found")), expect: 403)
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
      body = problem("forbidden")
      expect(scenario.verdict_from(response(403, body), expect: 403, expect_code: "forbidden").blocked).to be(true)
    end

    it "accepts any of several demanded codes" do
      body = problem("rls_denied")
      v = scenario.verdict_from(response(403, body), expect: 403, expect_code: %w[forbidden rls_denied])
      expect(v.blocked).to be(true)
    end

    it "does NOT block when the status matches but the code does not" do
      body = problem("kyc_required")
      v = scenario.verdict_from(response(403, body), expect: 403, expect_code: "forbidden")
      expect(v.blocked).to be(false)
      expect(v.detail).to include('want error.code "forbidden"')
    end

    it "does NOT block when the body carries no code at all" do
      v = scenario.verdict_from(response(403, {}), expect: 403, expect_code: "forbidden")
      expect(v.blocked).to be(false)
      expect(v.detail).to include("code=nil")
    end

    it "does NOT block when the body is not a problem document (not a Hash)" do
      v = scenario.verdict_from(response(403, ["nope"]), expect: 403, expect_code: "forbidden")
      expect(v.blocked).to be(false)
    end

    # The cutover moved the branch point out of a nested object. A stub — or an
    # origin — still speaking 0.3 must read as "no code", never as a match.
    it "does NOT block on a 0.3 `error` envelope carrying the demanded code" do
      nested = { "ok" => false, "error" => { "code" => "forbidden" } }
      v = scenario.verdict_from(response(403, nested), expect: 403, expect_code: "forbidden")
      expect(v.blocked).to be(false)
      expect(v.detail).to include("code=nil")
    end

    it "can demand a code without pinning the status" do
      body = problem("forbidden", status: 200)
      expect(scenario.verdict_from(response(200, body), expect_code: "forbidden").blocked).to be(true)
      expect(scenario.verdict_from(response(200, {}), expect_code: "forbidden").blocked).to be(false)
    end
  end

  describe "#error_code" do
    it "reads the problem document's top-level code" do
      expect(scenario.error_code(response(403, problem("forbidden")))).to eq("forbidden")
    end

    it "answers nil for a bare-array body, an empty body, and a 0.3 envelope" do
      # A non-paginating query answers a BARE ARRAY — not a Hash at all.
      expect(scenario.error_code(response(200, [{ "id" => "r1" }]))).to be_nil
      expect(scenario.error_code(response(403, {}))).to be_nil
      expect(scenario.error_code(response(403, "error" => { "code" => "forbidden" }))).to be_nil
    end
  end

  # ── #rows_from ───────────────────────────────────────────────────────────
  #
  # Every leak check in the library reads its rows through this one helper —
  # CrossTenantRead's control and attack legs, ForgedUserId's ownership check —
  # so what it can and cannot read decides what those scenarios can prove.
  describe "#rows_from" do
    # THE SHAPE THAT SHIPS (spec §8.2, T-092): EVERY query answers a bare JSON
    # array, paginating or not — truncation is an RFC 8288 `Link` header, not a
    # body field. Reading only `body["rows"]` would drop it: on a non-Hash body
    # that yields [], which reads identically to correct isolation.
    # CrossTenantRead's control would then fail loudly (safe), but
    # ForgedUserId's ownership check would answer "not leaked" and score a
    # VACUOUS BLOCKED — a security scenario passing an origin it never tested.
    it "reads a query's BARE ARRAY answer" do
      expect(scenario.rows_from(response(200, [{ "id" => "r1" }]))).to eq([{ "id" => "r1" }])
    end

    it "answers [] for an empty bare array, without confusing it with a hash" do
      expect(scenario.rows_from(response(200, []))).to eq([])
    end

    # THE COMPATIBILITY BRANCH, kept deliberately. This battery is pointed at
    # THIRD-PARTY origins, and one still serving a pre-T-092 cut answers a
    # truncated page as `{"rows": …, "next": …}`. Scoring such an origin
    # BLOCKED because we could not parse its answer is the worst outcome
    # available here; two lines buy the parse and cannot produce a false
    # ATTACK.
    it "still reads the rows of a legacy truncated page" do
      page = { "rows" => [{ "id" => "r1" }, { "id" => "r2" }], "next" => "b2Zmc2V0OjI" }
      expect(scenario.rows_from(response(200, page))).to eq([{ "id" => "r1" }, { "id" => "r2" }])
    end

    it "answers [] for a legacy page with no rows" do
      expect(scenario.rows_from(response(200, "rows" => []))).to eq([])
    end

    it "answers [] when `rows` is present but is not an array" do
      expect(scenario.rows_from(response(200, "rows" => "nope"))).to eq([])
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
