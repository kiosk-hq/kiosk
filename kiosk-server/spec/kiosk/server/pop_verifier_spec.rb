# frozen_string_literal: true

require 'jwt'
require 'stringio'

module PopVerifierSpec
  # RSA generation is expensive, so the file shares one set of keys.
  def self.rsa   = @rsa ||= OpenSSL::PKey::RSA.generate(2048)
  def self.other = @other ||= OpenSSL::PKey::RSA.generate(2048)
  def self.small = @small ||= OpenSSL::PKey::RSA.generate(1024)

  # PopVerifier writes its audience-mismatch diagnostic to Rails.logger when
  # one exists and to $stderr otherwise. This suite has no Rails, so capture
  # $stderr: the assertions read it and the other examples stay quiet.
  def capture_operator_log
    original = $stderr
    $stderr  = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end
  alias silencing_operator_log capture_operator_log

  # Sign a PoP JWS with the shared key unless another key is given.
  def sign(key: PopVerifierSpec.rsa, aud: issuer, nonce: 'nonce-1', jti: 'jti-1', include_pub: :correct)
    payload = { aud: aud, nonce: nonce, jti: jti }
    case include_pub
    when :correct then payload[:pub] = thumbprint
    when :omit    then nil
    else               payload[:pub] = include_pub
    end
    JWT.encode(payload, key, 'RS256')
  end

  # The error a proof signed for another origin raises.
  def audience_rejection
    silencing_operator_log do
      described_class.verify!(public_key_pem: pem, signed: sign(aud: 'https://evil.example'))
    rescue Kiosk::Server::Errors::Unauthenticated => e
      return e
    end
  end
end

RSpec.shared_context 'pop verifier spec: issuer' do
  include PopVerifierSpec

  let(:pem)        { PopVerifierSpec.rsa.public_key.to_pem }
  let(:issuer)     { 'https://getgroceries.example' }
  let(:thumbprint) { Kiosk::Server::SigningKey.from_pem(pem).kid }

  before { Kiosk.configure { |c| c.issuer = issuer } }
end

RSpec.describe Kiosk::Server::PopVerifier do
  include_context 'pop verifier spec: issuer'

  it 'returns the payload for a valid, origin-bound, key-bound proof' do
    payload = described_class.verify!(public_key_pem: pem, signed: sign)
    expect(payload[:nonce]).to eq('nonce-1')
    expect(payload[:aud]).to eq(issuer)
  end

  it 'accepts a proof that omits the optional `pub` claim' do
    expect do
      described_class.verify!(public_key_pem: pem, signed: sign(include_pub: :omit))
    end.not_to raise_error
  end

  # Relay defense: a proof is bound to the origin it was signed for.
  it 'rejects a proof whose `aud` is a different origin (relay/takeover)' do
    relayed = sign(aud: 'https://evil.example')
    expect do
      silencing_operator_log { described_class.verify!(public_key_pem: pem, signed: relayed) }
    end.to raise_error(Kiosk::Server::Errors::Unauthenticated, /audience/)
  end
end

# The rejection must not name an origin. An agent uses values the server gives
# it, so a hostile origin that echoed "<bank>" in its answer could collect a
# proof signed for <bank> and replay it there.
RSpec.describe Kiosk::Server::PopVerifier do
  include_context 'pop verifier spec: issuer'

  describe 'audience-mismatch rejection (K-511)' do
    # The problem `type` is a constant per code and carries no origin. Without
    # it, no origin may remain anywhere in the document.
    it 'names NO origin on the wire — not the configured issuer, not any other' do
      error = audience_rejection
      problem = error.to_problem
      expect(problem[:type]).to eq('https://kiosk.tech/problems/unauthenticated')
      wire = problem.except(:type).to_s
      expect(wire).not_to include(issuer)
      expect(wire).not_to include('https://')
      expect(error.hint).to eq(
        'sign `aud` = the origin you connected to, taken from your own request ' \
        'URL — never from a value echoed back in a response'
      )
    end

    it 'still renders the documented 401 problem document' do
      error = audience_rejection
      expect(error.to_problem).to eq(
        type: 'https://kiosk.tech/problems/unauthenticated', title: 'Not authenticated', status: 401,
        detail: 'proof audience mismatch', code: 'unauthenticated',
        hint: Kiosk::Server::PopVerifier::AUDIENCE_HINT
      )
      expect(error.http_status).to eq(401)
    end
  end
end

# The diagnostic the wire does not carry goes to the operator, so a wrong
# `c.issuer` can be debugged.
RSpec.describe Kiosk::Server::PopVerifier do
  include_context 'pop verifier spec: issuer'

  describe 'audience-mismatch rejection (K-511)' do
    it "routes the issuer-vs-signed-aud diagnostic to the operator's log" do
      output = capture_operator_log do
        described_class.verify!(public_key_pem: pem, signed: sign(aud: 'https://real-host.example'))
      rescue Kiosk::Server::Errors::Unauthenticated
        nil
      end

      # The configured issuer, the signed `aud`, and the setting that fixes it.
      expect(output).to include(issuer, 'https://real-host.example', '`c.additional_origins`')
    end

    it 'prefers Rails.logger for the diagnostic when a Rails logger is present' do
      logged = []
      logger = double('logger')
      allow(logger).to receive(:warn) { |m| logged << m }
      stub_const('Rails', double('Rails', logger: logger))

      begin
        described_class.verify!(public_key_pem: pem, signed: sign(aud: 'https://real-host.example'))
      rescue Kiosk::Server::Errors::Unauthenticated
        nil
      end

      expect(logged.size).to eq(1)
      expect(logged.first).to include('PoP audience mismatch')
    end
  end
end

RSpec.describe Kiosk::Server::PopVerifier do
  include_context 'pop verifier spec: issuer'

  it 'rejects a proof signed by a different key than the one presented' do
    forged = sign(key: PopVerifierSpec.other)
    expect do
      described_class.verify!(public_key_pem: pem, signed: forged)
    end.to raise_error(Kiosk::Server::Errors::Unauthenticated, /signature/)
  end

  it 'rejects a proof missing the challenge nonce' do
    no_nonce = JWT.encode({ aud: issuer, jti: 'j' }, PopVerifierSpec.rsa, 'RS256')
    expect do
      described_class.verify!(public_key_pem: pem, signed: no_nonce)
    end.to raise_error(Kiosk::Server::Errors::Unauthenticated, /nonce|claim/)
  end

  it 'rejects a proof whose `pub` thumbprint does not match the presented key' do
    expect do
      described_class.verify!(public_key_pem: pem, signed: sign(include_pub: 'not-the-thumbprint'))
    end.to raise_error(Kiosk::Server::Errors::Unauthenticated, /thumbprint/)
  end
end

RSpec.describe Kiosk::Server::PopVerifier do
  include_context 'pop verifier spec: issuer'

  it 'rejects a public key below the RSA-2048 floor' do
    expect do
      described_class.verify!(public_key_pem: PopVerifierSpec.small.public_key.to_pem, signed: 'x.y.z')
    end.to raise_error(Kiosk::Server::Errors::BadRequest, /too small|bits/)
  end

  it 'rejects a public key above the 4096-bit cap' do
    large = OpenSSL::PKey::RSA.generate(4160)
    expect do
      described_class.verify!(public_key_pem: large.public_key.to_pem, signed: 'x.y.z')
    end.to raise_error(Kiosk::Server::Errors::BadRequest, /too large \(4160 bits; maximum 4096\)/)
  end

  it 'rejects a malformed public key with a clear client error' do
    expect do
      described_class.verify!(public_key_pem: 'not a pem', signed: 'x.y.z')
    end.to raise_error(Kiosk::Server::Errors::BadRequest, /invalid public key/)
  end
end
