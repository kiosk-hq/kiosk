# frozen_string_literal: true

require "jwt"
require "stringio"

RSpec.describe Kiosk::Server::PopVerifier do
  # PopVerifier writes its operator-side audience-mismatch diagnostic to
  # Rails.logger when one exists and to $stderr otherwise — and this suite is
  # plain Ruby, no Rails. Capture it so the assertions can read it and the
  # unrelated examples don't spray the test output.
  def capture_operator_log
    original = $stderr
    $stderr  = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end
  alias_method :silencing_operator_log, :capture_operator_log

  # RSA generation is expensive — cache keypairs for the whole file.
  before(:all) do
    @rsa   = OpenSSL::PKey::RSA.generate(2048)
    @other = OpenSSL::PKey::RSA.generate(2048)
    @small = OpenSSL::PKey::RSA.generate(1024)
  end

  let(:pem)        { @rsa.public_key.to_pem }
  let(:issuer)     { "https://getgroceries.example" }
  let(:thumbprint) { Kiosk::Server::SigningKey.from_pem(pem).kid }

  before { Kiosk.configure { |c| c.issuer = issuer } }

  # Sign a PoP JWS with @rsa's private key unless another key is given.
  def sign(key: @rsa, aud: issuer, nonce: "nonce-1", jti: "jti-1", include_pub: :correct)
    payload = { aud: aud, nonce: nonce, jti: jti }
    case include_pub
    when :correct then payload[:pub] = thumbprint
    when :omit    then nil
    else               payload[:pub] = include_pub
    end
    JWT.encode(payload, key, "RS256")
  end

  it "returns the payload for a valid, origin-bound, key-bound proof" do
    payload = described_class.verify!(public_key_pem: pem, signed: sign)
    expect(payload[:nonce]).to eq("nonce-1")
    expect(payload[:aud]).to eq(issuer)
  end

  it "accepts a proof that omits the optional `pub` claim" do
    expect {
      described_class.verify!(public_key_pem: pem, signed: sign(include_pub: :omit))
    }.not_to raise_error
  end

  # ─── Relay defense (the whole point) ──────────────────────────────────────
  it "rejects a proof whose `aud` is a different origin (relay/takeover)" do
    relayed = sign(aud: "https://evil.example")
    expect {
      silencing_operator_log { described_class.verify!(public_key_pem: pem, signed: relayed) }
    }.to raise_error(Kiosk::Server::Errors::Unauthenticated, /audience/)
  end

  # ─── K-511: the rejection must not become the relay it defends against ────
  #
  # The old hint appended "(this provider is <issuer>)". That handed the caller
  # a concrete `aud` value read out of a RESPONSE — and an improvising agent
  # uses values the server just gave it, because every other step of the flow
  # rewards exactly that. A hostile origin could then answer any handshake with
  # "(this provider is <bank>)", collect the freshly signed PoP for <bank>, and
  # replay it at <bank>/auth/login for full account takeover.
  describe "audience-mismatch rejection (K-511)" do
    # The wire half: nothing that could be mistaken for an `aud` to sign.
    it "names NO origin on the wire — not the configured issuer, not any other" do
      error = nil
      silencing_operator_log do
        described_class.verify!(public_key_pem: pem, signed: sign(aud: "https://evil.example"))
      rescue Kiosk::Server::Errors::Unauthenticated => e
        error = e
      end

      wire = error.to_envelope.to_s
      expect(wire).not_to include(issuer)
      expect(wire).not_to include("https://")
      expect(error.hint).to eq(
        "sign `aud` = the origin you connected to, taken from your own request " \
        "URL — never from a value echoed back in a response",
      )
    end

    it "still renders the documented 401 envelope" do
      error = nil
      silencing_operator_log do
        described_class.verify!(public_key_pem: pem, signed: sign(aud: "https://evil.example"))
      rescue Kiosk::Server::Errors::Unauthenticated => e
        error = e
      end

      expect(error.to_envelope).to eq(
        ok: false,
        error: {
          code:    "unauthenticated",
          message: "proof audience mismatch",
          hint:    Kiosk::Server::PopVerifier::AUDIENCE_HINT,
        },
      )
      expect(error.http_status).to eq(401)
    end

    # The operator half: the diagnostic the wire no longer carries still has to
    # reach SOMEONE, or a misconfigured `c.issuer` (K-510) is undebuggable.
    it "routes the issuer-vs-signed-aud diagnostic to the operator's log" do
      output = capture_operator_log do
        described_class.verify!(public_key_pem: pem, signed: sign(aud: "https://real-host.example"))
      rescue Kiosk::Server::Errors::Unauthenticated
        nil
      end

      expect(output).to include(issuer)                      # what we are configured as
      expect(output).to include("https://real-host.example") # what the caller signed
      expect(output).to include("`c.issuer` is wrong")
    end

    it "prefers Rails.logger for the diagnostic when a Rails logger is present" do
      logged = []
      logger = double("logger")
      allow(logger).to receive(:warn) { |m| logged << m }
      stub_const("Rails", double("Rails", logger: logger))

      begin
        described_class.verify!(public_key_pem: pem, signed: sign(aud: "https://real-host.example"))
      rescue Kiosk::Server::Errors::Unauthenticated
        nil
      end

      expect(logged.size).to eq(1)
      expect(logged.first).to include("PoP audience mismatch")
    end
  end

  it "rejects a proof signed by a different key than the one presented" do
    forged = sign(key: @other) # signed by @other, verified against @rsa's public key
    expect {
      described_class.verify!(public_key_pem: pem, signed: forged)
    }.to raise_error(Kiosk::Server::Errors::Unauthenticated, /signature/)
  end

  it "rejects a proof missing the challenge nonce" do
    no_nonce = JWT.encode({ aud: issuer, jti: "j" }, @rsa, "RS256")
    expect {
      described_class.verify!(public_key_pem: pem, signed: no_nonce)
    }.to raise_error(Kiosk::Server::Errors::Unauthenticated, /nonce|claim/)
  end

  it "rejects a proof whose `pub` thumbprint does not match the presented key" do
    expect {
      described_class.verify!(public_key_pem: pem, signed: sign(include_pub: "not-the-thumbprint"))
    }.to raise_error(Kiosk::Server::Errors::Unauthenticated, /thumbprint/)
  end

  it "rejects a public key below the RSA-2048 floor" do
    expect {
      described_class.verify!(public_key_pem: @small.public_key.to_pem, signed: "x.y.z")
    }.to raise_error(Kiosk::Server::Errors::BadRequest, /too small|bits/)
  end

  it "rejects a malformed public key with a clear client error" do
    expect {
      described_class.verify!(public_key_pem: "not a pem", signed: "x.y.z")
    }.to raise_error(Kiosk::Server::Errors::BadRequest, /invalid public key/)
  end
end
