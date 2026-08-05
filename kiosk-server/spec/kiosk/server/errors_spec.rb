# frozen_string_literal: true

RSpec.describe Kiosk::Server::Errors do
  describe "HTTP-status + CODE mapping" do
    {
      Kiosk::Server::Errors::Base            => ["internal_error",  500],
      Kiosk::Server::Errors::BadRequest      => ["bad_request",     400],
      Kiosk::Server::Errors::Unauthenticated => ["unauthenticated", 401],
      Kiosk::Server::Errors::Forbidden       => ["forbidden",       403],
      Kiosk::Server::Errors::RLSDenied       => ["rls_denied",      403],
      Kiosk::Server::Errors::SpendingCapExceeded => ["spending_cap_exceeded", 403],
      Kiosk::Server::Errors::KycRequired     => ["kyc_required",    403],
      Kiosk::Server::Errors::NotFound        => ["not_found",       404],
      Kiosk::Server::Errors::QuotaExceeded   => ["quota_exceeded",  429],
      Kiosk::Server::Errors::ActionFailed    => ["action_failed",   500],
    }.each do |klass, (code, http_status)|
      it "#{klass.name.split('::').last} → code=#{code.inspect} http=#{http_status}" do
        instance = klass.new("boom")
        expect(instance.code).to        eq(code)
        expect(instance.http_status).to eq(http_status)
      end
    end
  end

  describe "Base#to_envelope" do
    it "produces a structured ok:false envelope" do
      e = Kiosk::Server::Errors::RLSDenied.new("denied", hint: "check policy")
      expect(e.to_envelope).to eq(
        ok: false,
        error: {
          code:    "rls_denied",
          message: "denied",
          hint:    "check policy",
        },
      )
    end

    it "drops nil hint from the envelope" do
      e = Kiosk::Server::Errors::BadRequest.new("nope")
      expect(e.to_envelope).to eq(
        ok: false,
        error: { code: "bad_request", message: "nope" },
      )
    end
  end

  describe ".unknown_name_hint" do
    it "names the available names and points at the schema, matching the example shape" do
      hint = described_class.unknown_name_hint("listings", "query", %w[browse_listings listing_detail])
      expect(hint).to eq(
        "unknown query 'listings'. Available: browse_listings, listing_detail. " \
        "Call GET .../schema for the full catalog.",
      )
    end

    it "caps the enumerated names at 20 and appends an ellipsis" do
      names = (0...30).map { |i| format("q%02d", i) }
      hint  = described_class.unknown_name_hint("nope", "query", names)
      expect(hint).to include("q00")
      expect(hint).to include("q19")
      expect(hint).not_to include("q20")
      expect(hint).to include(", ….")
    end

    it "handles an empty registry without listing names but still points at the schema" do
      hint = described_class.unknown_name_hint("x", "action", [])
      expect(hint).to eq("unknown action 'x'. No actions are registered. Call GET .../schema for the full catalog.")
    end
  end

  describe "rescue-by-Base contract" do
    it "every Kiosk::Server::Errors::* subclass rescues as Base" do
      [Kiosk::Server::Errors::BadRequest, Kiosk::Server::Errors::Unauthenticated,
       Kiosk::Server::Errors::Forbidden,  Kiosk::Server::Errors::RLSDenied,
       Kiosk::Server::Errors::SpendingCapExceeded,
       Kiosk::Server::Errors::KycRequired,
       Kiosk::Server::Errors::NotFound,   Kiosk::Server::Errors::QuotaExceeded,
       Kiosk::Server::Errors::ActionFailed].each do |klass|
        begin
          raise klass, "x"
        rescue Kiosk::Server::Errors::Base => caught
          expect(caught).to be_a(klass)
        end
      end
    end
  end
end
