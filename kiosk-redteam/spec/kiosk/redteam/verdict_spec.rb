# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Kiosk::Redteam.blocked?" do
  def response(status, body = {})
    Kiosk::Redteam::Response.new(status:, body:)
  end

  # ── Explicit block statuses ──────────────────────────────────────────────

  it "returns true for HTTP 401" do
    expect(Kiosk::Redteam.blocked?(response(401))).to be(true)
  end

  it "returns true for HTTP 403" do
    expect(Kiosk::Redteam.blocked?(response(403))).to be(true)
  end

  # ── HTTP 402: the overloaded status (K-736) ──────────────────────────────
  #
  # kiosk-server maps THREE codes onto 402 (Errors::CODES) and this predicate
  # answered true for the bare status, so a tolled verb printed
  # "BLOCKED ✓ … (HTTP 402)" for an attack that never executed. Pin all three
  # plus the bare status: none of them is a refusal this predicate can read.
  it "returns false for HTTP 402 pow_required (a toll defers, it does not refuse)" do
    expect(Kiosk::Redteam.blocked?(response(402, problem("pow_required")))).to be(false)
  end

  it "returns false for HTTP 402 payment_setup_required (no card on file is the attacker's gap)" do
    expect(Kiosk::Redteam.blocked?(response(402, problem("payment_setup_required")))).to be(false)
  end

  it "returns false for HTTP 402 payment_failed (the rail declined; every gate had said yes)" do
    expect(Kiosk::Redteam.blocked?(response(402, problem("payment_failed")))).to be(false)
  end

  it "returns false for a bare HTTP 402 naming no code at all" do
    expect(Kiosk::Redteam.blocked?(response(402))).to be(false)
  end

  # The three codes disqualify a response whatever status carries them: a
  # status and a `code` that disagree are the least conclusive answer there
  # is, and `pow_required` on a 200 was a block until K-736.
  it "returns false for a 403 whose problem document says payment_failed (status and code disagree)" do
    expect(Kiosk::Redteam.blocked?(response(403, problem("payment_failed", status: 403)))).to be(false)
  end

  describe ".payment_required_reason" do
    it "names which of the three answered" do
      Kiosk::Redteam::PAYMENT_REQUIRED_CODES.each_key do |code|
        reason = Kiosk::Redteam.payment_required_reason(response(402, problem(code)))
        expect(reason).to include(code.inspect)
        expect(reason).to include("HTTP 402")
      end
    end

    it "says the bare status named none of them" do
      expect(Kiosk::Redteam.payment_required_reason(response(402))).to include("named none of them")
    end

    it "is nil for anything that is not a 402 answer" do
      expect(Kiosk::Redteam.payment_required_reason(response(403, problem("forbidden")))).to be_nil
      expect(Kiosk::Redteam.payment_required_reason(response(200))).to be_nil
    end
  end

  # ── Not blocked ──────────────────────────────────────────────────────────

  it "returns false for HTTP 200 (success is not a block)" do
    expect(Kiosk::Redteam.blocked?(response(200))).to be(false)
  end

  it "returns false for HTTP 201" do
    expect(Kiosk::Redteam.blocked?(response(201))).to be(false)
  end

  # Critical: a server crash must NOT count as 'blocked'.
  it "returns false for HTTP 500 (crash is not a block)" do
    expect(Kiosk::Redteam.blocked?(response(500, problem("internal_error")))).to be(false)
  end

  it "returns false for HTTP 503" do
    expect(Kiosk::Redteam.blocked?(response(503))).to be(false)
  end

  # K-728: the denial-code branch used to run with no status guard, so a 500
  # rendering the envelope a crashing authorization filter renders was counted
  # as a block — the exact masquerade the 5xx rule exists to forbid.
  it "returns false for HTTP 500 carrying a recognised denial code (crash-masquerade guard)" do
    expect(Kiosk::Redteam.blocked?(response(500, problem("forbidden", status: 500)))).to be(false)
  end

  it "returns false for HTTP 502 carrying 'rls_denied'" do
    expect(Kiosk::Redteam.blocked?(response(502, problem("rls_denied", status: 502)))).to be(false)
  end

  # status 0 is the connection-error sentinel: nothing answered, so nothing
  # was enforced, whatever a body claims.
  it "returns false for a connection error (status 0) even with a denial code" do
    expect(Kiosk::Redteam.blocked?(response(0, problem("unauthenticated")))).to be(false)
  end

  it "returns false for HTTP 422 (unprocessable entity is not a security block)" do
    expect(Kiosk::Redteam.blocked?(response(422, problem("bad_request", status: 422)))).to be(false)
  end

  # ── Domain error codes ───────────────────────────────────────────────────

  it "returns true for error code 'forbidden' even on HTTP 200" do
    expect(Kiosk::Redteam.blocked?(response(200, problem("forbidden", status: 200)))).to be(true)
  end

  it "returns true for error code 'unauthenticated'" do
    expect(Kiosk::Redteam.blocked?(response(200, problem("unauthenticated", status: 200)))).to be(true)
  end

  # pow_required was in BLOCKED_ERROR_CODES until K-736 — so a provider that
  # answered 200 with a toll envelope scored a block for a deferred request.
  it "returns false for error code 'pow_required' (a demanded toll is not a denial)" do
    expect(Kiosk::Redteam.blocked?(response(200, problem("pow_required", status: 200)))).to be(false)
  end

  it "returns true for error code 'rls_denied'" do
    expect(Kiosk::Redteam.blocked?(response(200, problem("rls_denied", status: 200)))).to be(true)
  end

  # bad_request is intentionally excluded: a 400 validation error is NOT
  # evidence of an auth/authz gate; RegistrationWithoutPow uses its own check.
  it "returns false for error code 'bad_request' (not an auth denial)" do
    expect(Kiosk::Redteam.blocked?(response(200, problem("bad_request", status: 200)))).to be(false)
  end

  it "returns false for an unrecognised domain error code" do
    expect(Kiosk::Redteam.blocked?(response(200, problem("internal_error", status: 200)))).to be(false)
  end

  it "returns false when body is an empty hash (no error code present)" do
    expect(Kiosk::Redteam.blocked?(response(200, {}))).to be(false)
  end

  # ── The branch point moved with the cutover ──────────────────────────────
  #
  # A problem document is FLAT: `code` is a top-level extension member. 0.3's
  # `{ok:false, error:{code:}}` envelope is not a shape this wire emits any
  # more, and reading a code out of one would mean this gem scored verdicts off
  # a body no origin sends — so it must answer nil and the verdict must fall
  # through to the status.
  it "reads the code off the problem document itself, not out of a nested envelope" do
    flat = problem("forbidden", status: 200)
    expect(Kiosk::Redteam.error_code(response(200, flat))).to eq("forbidden")
  end

  it "does NOT read a 0.3 `error` envelope (that wire is gone)" do
    nested = { "ok" => false, "error" => { "code" => "forbidden" } }
    expect(Kiosk::Redteam.error_code(response(200, nested))).to be_nil
    expect(Kiosk::Redteam.blocked?(response(200, nested))).to be(false)
  end

  # A non-paginating query answers a BARE ARRAY — a body that is not a Hash at
  # all, and the one success shape most likely to reach this predicate.
  it "answers nil for a bare-array body (a non-paginating query's answer)" do
    expect(Kiosk::Redteam.error_code(response(200, [{ "id" => "r1" }]))).to be_nil
  end

  # ── Verdict struct ───────────────────────────────────────────────────────

  describe Kiosk::Redteam::Verdict do
    it "is a Data with blocked, skipped, status, and detail" do
      v = described_class.new(blocked: true, skipped: false, status: 403, detail: "forbidden")
      expect(v.blocked).to be(true)
      expect(v.skipped).to be(false)
      expect(v.status).to eq(403)
      expect(v.detail).to eq("forbidden")
    end

    it "is immutable (frozen)" do
      v = described_class.new(blocked: false, skipped: false, status: 200, detail: "breach!")
      expect(v).to be_frozen
    end

    it "carries skipped: true for a skip verdict" do
      v = described_class.new(blocked: false, skipped: true, status: 0, detail: "SKIP — no gated_action")
      expect(v.skipped).to be(true)
      expect(v.blocked).to be(false)
    end
  end
end
