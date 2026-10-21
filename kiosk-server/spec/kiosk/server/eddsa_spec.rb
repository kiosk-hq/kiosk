# frozen_string_literal: true

# EdDSA (RFC 8037) over OpenSSL, held to the test vectors of RFC 8037 Appendix A.
RSpec.describe Kiosk::Server::Eddsa do
  # RFC 8037 A.1: the private key `d` and the public key `x`.
  let(:d) { 'nWGxne_9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A' }
  let(:x) { '11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo' }
  let(:key) { OpenSSL::PKey.new_raw_private_key('ED25519', Base64.urlsafe_decode64(d)) }
  # RFC 8037 A.4: the JWS of the payload "Example of Ed25519 signing" under the header {"alg":"EdDSA"}.
  let(:jws) do
    'eyJhbGciOiJFZERTQSJ9.RXhhbXBsZSBvZiBFZDI1NTE5IHNpZ25pbmc.' \
      'hgyY0il_MGCjP0JzlnLWG1PPOt7-09PGcvMg3AIbQR6dWbhijcNR4ki4iylGjg5BhVsPt9g7sVvpAr_MuM0KAg'
  end
  let(:public_key) { Kiosk::Server::Jwk.import(kty: 'OKP', crv: 'Ed25519', x: x) }

  it 'signs the RFC 8037 A.4 JWS byte for byte' do
    signing_input = jws.split('.').first(2).join('.')
    signature = described_class.new.sign(data: signing_input, signing_key: key)
    expect(Base64.urlsafe_encode64(signature, padding: false)).to eq(jws.split('.').last)
  end

  it 'verifies the RFC 8037 A.4 JWS with the public key of A.2, and refuses it with one signature byte changed' do
    signing_input, _, signature = jws.rpartition('.')
    verify = ->(sig) { described_class.new.verify(data: signing_input, signature: Base64.urlsafe_decode64(sig), verification_key: public_key) }
    expect([verify.call(signature), verify.call(signature.sub(/\Ah/, 'i'))]).to eq([true, false])
  end

  it 'signs and verifies a JWT through ruby-jwt by the name EdDSA' do
    token = JWT.encode({ 'sub' => 'a' }, key, 'EdDSA')
    expect(JWT.decode(token, public_key, true, algorithms: ['EdDSA'])).to eq([{ 'sub' => 'a' }, { 'alg' => 'EdDSA' }])
  end

  it 'refuses a key that is not an Ed25519 key' do
    p256 = OpenSSL::PKey::EC.generate('prime256v1')
    expect { JWT.encode({}, p256, 'EdDSA') }.to raise_error(JWT::EncodeError, /Ed25519/)
    expect { JWT.decode(jws, p256, true, algorithms: ['EdDSA']) }.to raise_error(JWT::DecodeError, /Ed25519/)
  end

  it 'gives the RFC 8037 A.3 thumbprint of the public key' do
    expect(Kiosk::Server::Jwk.thumbprint(public_key)).to eq('kPrK_qmxVWaYVA9wwBF6Iuo3vVzz7TxHCTwXBygrS4k')
    expect(Kiosk::Server::Jwk.public_members(key)).to eq(crv: 'Ed25519', kty: 'OKP', x: x)
  end
end
