# frozen_string_literal: true

RSpec.describe Kiosk::Server::Errors do
  describe "CODES — the wire vocabulary" do
    it "is exactly the spec's closed error.code table" do
      expect(described_class::CODES).to eq(
        "bad_request"            => 400,
        "unauthenticated"        => 401,
        "pow_required"           => 402,
        "payment_setup_required" => 402,
        "payment_failed"         => 402,
        "forbidden"              => 403,
        "rls_denied"             => 403,
        "spending_cap_exceeded"  => 403,
        "kyc_required"           => 403,
        "not_found"              => 404,
        "conflict"               => 409,
        "quota_exceeded"         => 429,
        "action_failed"          => 500,
        "internal_error"         => 500,
      )
    end
  end

  describe "STATUS_CODES — the Rails-native mapping" do
    it "never guesses 402 (three codes share it) or 500 (action_failed vs internal_error)" do
      expect(described_class::STATUS_CODES).not_to have_key(402)
      expect(described_class::STATUS_CODES).not_to have_key(500)
    end

    it "maps every status to a vocabulary code" do
      described_class::STATUS_CODES.each_value do |code|
        expect(described_class::CODES).to have_key(code)
      end
    end

    it "answers 422 with bad_request — Rails' validation idiom, one wire code" do
      expect(described_class::STATUS_CODES[422]).to eq("bad_request")
    end
  end

  describe "the exception classes" do
    # Every Errors class with a CODE constant, found rather than listed, so a
    # class added without a vocabulary entry cannot slip past this contract.
    def coded_classes
      described_class.constants
                     .map { |name| described_class.const_get(name) }
                     .select { |c| c.is_a?(Class) && c < described_class::Base && c.const_defined?(:CODE, false) }
    end

    it "each agrees with the CODES table on both code and status" do
      expect(coded_classes).not_to be_empty
      coded_classes.each do |klass|
        code = klass.const_get(:CODE)
        expect(described_class::CODES[code]).to eq(klass.const_get(:HTTP_STATUS)),
          "#{klass}: CODE #{code.inspect} / HTTP_STATUS #{klass.const_get(:HTTP_STATUS)} disagrees with CODES"
      end
    end

    it "reserves quota_exceeded as vocabulary only — the class was deleted, nothing raised it" do
      expect(described_class.const_defined?(:QuotaExceeded)).to be(false)
      expect(described_class::CODES["quota_exceeded"]).to eq(429)
    end

    {
      Kiosk::Server::Errors::Base            => ["internal_error",  500],
      Kiosk::Server::Errors::BadRequest      => ["bad_request",     400],
      Kiosk::Server::Errors::Unauthenticated => ["unauthenticated", 401],
      Kiosk::Server::Errors::Forbidden       => ["forbidden",       403],
      Kiosk::Server::Errors::RLSDenied       => ["rls_denied",      403],
      Kiosk::Server::Errors::SpendingCapExceeded => ["spending_cap_exceeded", 403],
      Kiosk::Server::Errors::KycRequired     => ["kyc_required",    403],
      Kiosk::Server::Errors::NotFound        => ["not_found",       404],
      Kiosk::Server::Errors::ActionFailed    => ["action_failed",   500],
    }.each do |klass, (code, http_status)|
      it "#{klass.name.split('::').last} → code=#{code.inspect} http=#{http_status}" do
        instance = klass.new("boom")
        expect(instance.code).to        eq(code)
        expect(instance.http_status).to eq(http_status)
      end
    end
  end

  describe "WireError — a code as data, not a class" do
    it "takes any vocabulary code and answers with its canonical status" do
      e = described_class::WireError.new("row policy said no", code: "rls_denied", hint: "check policy")
      expect(e.code).to        eq("rls_denied")
      expect(e.http_status).to eq(403)
      expect(e.to_envelope).to eq(
        ok:    false,
        error: { code: "rls_denied", message: "row policy said no", hint: "check policy" },
      )
    end

    it "carries extra envelope fields through verbatim" do
      e = described_class::WireError.new("proof-of-work required",
                                         code: "pow_required", extra: { challenges: [{ n: 1 }] })
      expect(e.to_envelope[:error][:challenges]).to eq([{ n: 1 }])
    end

    it "refuses a code outside the closed vocabulary" do
      expect { described_class::WireError.new("x", code: "out_of_stock") }
        .to raise_error(ArgumentError, /unknown wire code "out_of_stock"/)
    end

    it "rescues as Base, like every wire error" do
      expect(described_class::WireError.new("x", code: "conflict")).to be_a(described_class::Base)
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

    it "pluralises the other half of the vocabulary as English does" do
      # This branch is reachable ONLY when nothing is registered for the kind,
      # which until the T-057 pilot hit that state meant nobody had read
      # "No querys are registered" out loud.
      hint = described_class.unknown_name_hint("x", "query", [])
      expect(hint).to eq("unknown query 'x'. No queries are registered. Call GET .../schema for the full catalog.")
    end
  end

  describe "rescue-by-Base contract" do
    it "every Kiosk::Server::Errors::* subclass rescues as Base" do
      [Kiosk::Server::Errors::BadRequest, Kiosk::Server::Errors::Unauthenticated,
       Kiosk::Server::Errors::Forbidden,  Kiosk::Server::Errors::RLSDenied,
       Kiosk::Server::Errors::SpendingCapExceeded,
       Kiosk::Server::Errors::KycRequired,
       Kiosk::Server::Errors::NotFound,
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
