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

  it "returns true for HTTP 402" do
    expect(Kiosk::Redteam.blocked?(response(402))).to be(true)
  end

  it "returns true for HTTP 403" do
    expect(Kiosk::Redteam.blocked?(response(403))).to be(true)
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
    expect(Kiosk::Redteam.blocked?(response(500, { "error" => "internal server error" }))).to be(false)
  end

  it "returns false for HTTP 503" do
    expect(Kiosk::Redteam.blocked?(response(503))).to be(false)
  end

  # K-728: the denial-code branch used to run with no status guard, so a 500
  # rendering the envelope a crashing authorization filter renders was counted
  # as a block — the exact masquerade the 5xx rule exists to forbid.
  it "returns false for HTTP 500 carrying a recognised denial code (crash-masquerade guard)" do
    body = { "error" => { "code" => "forbidden" } }
    expect(Kiosk::Redteam.blocked?(response(500, body))).to be(false)
  end

  it "returns false for HTTP 502 carrying 'rls_denied'" do
    body = { "error" => { "code" => "rls_denied" } }
    expect(Kiosk::Redteam.blocked?(response(502, body))).to be(false)
  end

  # status 0 is the connection-error sentinel: nothing answered, so nothing
  # was enforced, whatever a body claims.
  it "returns false for a connection error (status 0) even with a denial code" do
    body = { "error" => { "code" => "unauthenticated" } }
    expect(Kiosk::Redteam.blocked?(response(0, body))).to be(false)
  end

  it "returns false for HTTP 422 (unprocessable entity is not a security block)" do
    expect(Kiosk::Redteam.blocked?(response(422, { "error" => { "code" => "unprocessable" } }))).to be(false)
  end

  # ── Domain error codes ───────────────────────────────────────────────────

  it "returns true for error code 'forbidden' even on HTTP 200" do
    body = { "error" => { "code" => "forbidden" } }
    expect(Kiosk::Redteam.blocked?(response(200, body))).to be(true)
  end

  it "returns true for error code 'unauthenticated'" do
    body = { "error" => { "code" => "unauthenticated" } }
    expect(Kiosk::Redteam.blocked?(response(200, body))).to be(true)
  end

  it "returns true for error code 'pow_required'" do
    body = { "error" => { "code" => "pow_required" } }
    expect(Kiosk::Redteam.blocked?(response(200, body))).to be(true)
  end

  it "returns true for error code 'rls_denied'" do
    body = { "error" => { "code" => "rls_denied" } }
    expect(Kiosk::Redteam.blocked?(response(200, body))).to be(true)
  end

  # bad_request is intentionally excluded: a 400 validation error is NOT
  # evidence of an auth/authz gate; RegistrationWithoutPow uses its own check.
  it "returns false for error code 'bad_request' (not an auth denial)" do
    body = { "error" => { "code" => "bad_request" } }
    expect(Kiosk::Redteam.blocked?(response(200, body))).to be(false)
  end

  it "returns false for an unrecognised domain error code" do
    body = { "error" => { "code" => "internal_error" } }
    expect(Kiosk::Redteam.blocked?(response(200, body))).to be(false)
  end

  it "returns false when body is an empty hash (no error code present)" do
    expect(Kiosk::Redteam.blocked?(response(200, {}))).to be(false)
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
