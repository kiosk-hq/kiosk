# frozen_string_literal: true

require 'jwt'
require 'openssl'

module KycVerifierSpec
  # Sign a KYC attestation payload with the test KYC key.
  def sign_kyc(payload)
    JWT.encode(payload, kyc_key, 'EdDSA')
  end

  def valid_payload(**overrides)
    {
      sub: 'u-1', level: 'verified',
      iss: kyc_issuer, aud: kyc_audience, iat: (Time.current - 5).to_i, exp: future
    }.merge(overrides)
  end
end

RSpec.shared_context 'with a configured KYC verifier' do
  include KycVerifierSpec

  let(:kyc_key)      { OpenSSL::PKey.generate_key('ED25519') }
  let(:kyc_issuer)   { 'https://kyc.example' }
  let(:kyc_audience) { 'acme-operator' }
  let(:future)       { (Time.current + 600).to_i }
  let(:past)         { (Time.current - 600).to_i }

  before do
    Kiosk.configure do |c|
      c.kyc_issuer     = kyc_issuer
      c.kyc_audience   = kyc_audience
      c.kyc_public_key = kyc_key
    end
  end
end

RSpec.describe Kiosk::Server::KycVerifier do
  describe '.verify' do
    include_context 'with a configured KYC verifier'

    it 'returns claims hash for a valid attestation' do
      raw_jws = sign_kyc(valid_payload)
      claims  = described_class.verify(raw_jws: raw_jws, subject: 'u-1')
      expect(claims[:sub]).to   eq('u-1')
      expect(claims[:level]).to eq('verified')
      expect(claims[:iss]).to   eq(kyc_issuer)
    end

    it 'returns an empty attribute set for a bare binary attestation (backward-compat)' do
      claims = described_class.verify(raw_jws: sign_kyc(valid_payload), subject: 'u-1')
      expect(claims[:attributes]).to eq({})
    end

    # Named anonymized attributes.
    it 'returns the granted named boolean attributes (String-keyed)' do
      raw_jws = sign_kyc(valid_payload(attributes: { 'age_over_18' => true, 'licence_a' => true }))
      claims  = described_class.verify(raw_jws: raw_jws, subject: 'u-1')
      expect(claims[:attributes]).to eq('age_over_18' => true, 'licence_a' => true)
    end

    it 'drops any non-true attribute value (no truthy-but-not-true grants)' do
      attributes = { 'age_over_18' => true, 'licence_a' => false, 'licence_b' => 'yes', 'extra' => 1 }
      raw_jws = sign_kyc(valid_payload(attributes: attributes))
      claims = described_class.verify(raw_jws: raw_jws, subject: 'u-1')
      expect(claims[:attributes]).to eq('age_over_18' => true)
    end

    it 'raises Errors::Forbidden when attributes is not an object' do
      raw_jws = sign_kyc(valid_payload(attributes: ['age_over_18']))
      expect { described_class.verify(raw_jws: raw_jws, subject: 'u-1') }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /attributes must be an object/)
    end

    # The issuer and the audience bind a claim to this operator. A claim minted
    # for another operator's audience does not unlock this one.
    it 'raises Errors::Forbidden when the iss does not match kyc_issuer' do
      raw_jws = sign_kyc(valid_payload(iss: 'https://evil-kyc.example'))
      expect { described_class.verify(raw_jws: raw_jws, subject: 'u-1') }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /issuer/)
    end

    it "raises Errors::Forbidden when aud does not match this operator's kyc_audience" do
      raw_jws = sign_kyc(valid_payload(aud: 'other-operator'))
      expect { described_class.verify(raw_jws: raw_jws, subject: 'u-1') }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /audience/)
    end

    it 'raises Errors::Forbidden when the aud claim is absent' do
      raw_jws = sign_kyc(valid_payload.except(:aud))
      expect { described_class.verify(raw_jws: raw_jws, subject: 'u-1') }
        .to raise_error(Kiosk::Server::Errors::Forbidden)
    end

    it 'accepts an attestation whose aud matches kyc_audience (happy path)' do
      raw_jws = sign_kyc(valid_payload(aud: kyc_audience))
      claims  = described_class.verify(raw_jws: raw_jws, subject: 'u-1')
      expect(claims[:aud]).to eq(kyc_audience)
      expect(claims[:level]).to eq('verified')
    end

    it 'defaults kyc_audience to the operator issuer when not explicitly set' do
      Kiosk.configure do |c|
        c.kyc_audience = nil
        c.issuer       = 'https://operator.example'
      end
      raw_jws = sign_kyc(valid_payload(aud: 'https://operator.example'))
      claims  = described_class.verify(raw_jws: raw_jws, subject: 'u-1')
      expect(claims[:aud]).to eq('https://operator.example')
    end

    # The subject check compares as String on both sides: a bigint-PK host has an
    # Integer user_id, and the KYC provider signs `sub` as a String.
    it 'raises Errors::Forbidden when the sub does not match identity.user_id' do
      raw_jws = sign_kyc(valid_payload(sub: 'u-other'))
      expect { described_class.verify(raw_jws: raw_jws, subject: 'u-1') }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /subject/)
    end

    context 'when on a bigint-PK host (Integer identity, String attestation sub)' do
      it 'verifies an Integer identity against a String attestation sub' do
        claims = described_class.verify(raw_jws: sign_kyc(valid_payload(sub: '42')), subject: 42)
        expect(claims[:sub]).to eq('42')
        expect(claims[:level]).to eq('verified')
      end

      it 'still rejects a genuinely different subject (43 != 42)' do
        raw_jws = sign_kyc(valid_payload(sub: '43'))
        expect { described_class.verify(raw_jws: raw_jws, subject: 42) }
          .to raise_error(Kiosk::Server::Errors::Forbidden, /subject/)
      end
    end

    it 'raises Errors::Forbidden for an expired attestation' do
      raw_jws = sign_kyc(valid_payload(exp: past))
      expect { described_class.verify(raw_jws: raw_jws, subject: 'u-1') }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /expired/)
    end

    it 'raises Errors::Forbidden for a tampered / wrong-key signature' do
      other_key = OpenSSL::PKey.generate_key('ED25519')
      raw_jws   = JWT.encode(valid_payload, other_key, 'EdDSA')
      expect { described_class.verify(raw_jws: raw_jws, subject: 'u-1') }
        .to raise_error(Kiosk::Server::Errors::Forbidden)
    end

    it 'raises Errors::Forbidden for an attestation signed RS256' do
      raw_jws = JWT.encode(valid_payload, OpenSSL::PKey::RSA.generate(2048), 'RS256')
      expect { described_class.verify(raw_jws: raw_jws, subject: 'u-1') }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /signature invalid/)
    end

    # An origin with no `kyc_public_key` serves no KYC at all. That is an
    # origin-wide fact, so the answer is module_not_served (501), not forbidden.
    context 'without a kyc_public_key' do
      before { Kiosk.configure { |c| c.kyc_public_key = nil } }

      it 'raises Errors::ModuleNotServed when kyc_public_key is not configured' do
        expect { described_class.verify(raw_jws: sign_kyc(valid_payload), subject: 'u-1') }
          .to raise_error(Kiosk::Server::Errors::ModuleNotServed, /does not serve the KYC module/)
      end

      it 'puts module_not_served/501 on the wire for it, and names the module in detail' do
        expect { described_class.verify(raw_jws: sign_kyc(valid_payload), subject: 'u-1') }
          .to raise_error(Kiosk::Server::Errors::ModuleNotServed) { |e|
            expect(e.code).to        eq('module_not_served')
            expect(e.http_status).to eq(501)
            expect(e.to_problem[:type]).to   eq('https://kiosk.tech/problems/module_not_served')
            expect(e.to_problem[:detail]).to include('KYC')
            # An assistant that branches on `forbidden` must not catch this.
            expect(e).not_to be_a(Kiosk::Server::Errors::Forbidden)
          }
      end
    end

    it "I1: raises Errors::Forbidden when level is not 'verified' (e.g. 'pending')" do
      raw_jws = sign_kyc(valid_payload(level: 'pending'))
      expect { described_class.verify(raw_jws: raw_jws, subject: 'u-1') }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /kyc level not verified/)
    end

    it 'I1: raises Errors::Forbidden when level is missing entirely' do
      raw_jws = sign_kyc(valid_payload.except(:level))
      expect { described_class.verify(raw_jws: raw_jws, subject: 'u-1') }
        .to raise_error(Kiosk::Server::Errors::Forbidden, /kyc level not verified/)
    end

    %i[exp iss sub].each do |claim|
      it "I2: raises Errors::Forbidden when #{claim} claim is absent" do
        raw_jws = sign_kyc(valid_payload.except(claim))
        expect { described_class.verify(raw_jws: raw_jws, subject: 'u-1') }
          .to raise_error(Kiosk::Server::Errors::Forbidden)
      end
    end
  end
end
