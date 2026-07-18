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

  describe "rescue-by-Base contract" do
    it "every Kiosk::Server::Errors::* subclass rescues as Base" do
      [Kiosk::Server::Errors::BadRequest, Kiosk::Server::Errors::Unauthenticated,
       Kiosk::Server::Errors::Forbidden,  Kiosk::Server::Errors::RLSDenied,
       Kiosk::Server::Errors::SpendingCapExceeded,
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
