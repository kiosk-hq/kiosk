# frozen_string_literal: true

RSpec.describe Kiosk::Server::Errors do
  describe "exit-code + HTTP-status + CODE mapping (spec §5.2)" do
    {
      Kiosk::Server::Errors::Base            => ["internal_error", 6, 500],
      Kiosk::Server::Errors::BadRequest      => ["bad_request",    2, 400],
      Kiosk::Server::Errors::Unauthenticated => ["unauthenticated", 3, 401],
      Kiosk::Server::Errors::Forbidden       => ["forbidden",      3, 403],
      Kiosk::Server::Errors::RLSDenied       => ["rls_denied",     4, 403],
      Kiosk::Server::Errors::NotFound        => ["not_found",      2, 404],
      Kiosk::Server::Errors::QuotaExceeded   => ["quota_exceeded", 5, 429],
      Kiosk::Server::Errors::ActionFailed    => ["action_failed",  6, 500],
    }.each do |klass, (code, exit_code, http_status)|
      it "#{klass.name.split('::').last} → code=#{code.inspect} exit=#{exit_code} http=#{http_status}" do
        instance = klass.new("boom")
        expect(instance.code).to        eq(code)
        expect(instance.exit_code).to   eq(exit_code)
        expect(instance.http_status).to eq(http_status)
      end
    end
  end

  describe "Base#to_envelope" do
    it "produces a structured ok:false envelope" do
      e = Kiosk::Server::Errors::RLSDenied.new("denied", hint: "check policy", query_id: "q-42")
      expect(e.to_envelope).to eq(
        ok: false,
        error: {
          code:     "rls_denied",
          message:  "denied",
          hint:     "check policy",
          query_id: "q-42",
        },
      )
    end

    it "drops nil hint and query_id from the envelope" do
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
