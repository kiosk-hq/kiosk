# frozen_string_literal: true

require "jwt"

RSpec.describe Kiosk::Server::PopVerifier do
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
      described_class.verify!(public_key_pem: pem, signed: relayed)
    }.to raise_error(Kiosk::Server::Errors::Unauthenticated, /audience/)
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
