# frozen_string_literal: true

# AuthController#rotate: the guards that turn a malformed body into a 400
# problem document, never a 500. The rotation itself runs against the real
# table in auth_plane_persistence_spec.rb.
#
# Dispatch goes through `ActionController::Metal.action(...)`, a plain Rack
# app — no Rails host.

require 'rack/mock'
require 'json'

RSpec.describe Kiosk::Server::AuthController do
  before { Kiosk.configure { |c| c.issuer = 'https://demo.example' } }

  def rotate(raw_body)
    env = Rack::MockRequest.env_for('https://demo.example/kiosk/auth/rotate', method: 'POST', input: raw_body,
                                                                              'CONTENT_TYPE' => 'application/json')
    status, headers, body = described_class.action(:rotate).call(env)
    raw = +''
    body.each { |chunk| raw << chunk }
    [status, headers, JSON.parse(raw)]
  end

  # The auth plane answers the same RFC 9457 problem document as the verbs:
  # `application/problem+json`, a per-code `type` and `title`, the status in
  # the body, and the closed-vocabulary `code` at the top level.
  def expect_problem(response, http:, code:, detail: nil)
    status, headers, body = response
    expect(status).to eq(http)
    expect(headers['Content-Type']).to include('application/problem+json')
    expect(body).to include('type' => "https://kiosk.tech/problems/#{code}", 'status' => http, 'code' => code,
                            'title' => Kiosk::Server::Errors::TITLES.fetch(code))
    expect(body['detail']).to include(detail) if detail
  end

  let(:complete) do
    { client_assertion_type: Kiosk::Server::ClientAssertion::TYPE, client_assertion: 'a.b.c',
      new_client_assertion: 'd.e.f', jwks: { keys: [Kiosk::Server::AssistantKey.to_jwk(agent_key)] } }
  end

  it 'answers 400 bad_request for an empty body, invalid JSON and a body that is not an object' do
    ['', '{not valid json', '[1,2,3]'].each { expect_problem(rotate(it), http: 400, code: 'bad_request') }
  end

  it 'answers 400 bad_request naming each member that is absent' do
    %i[client_assertion_type client_assertion new_client_assertion jwks].each do |member|
      expect_problem(rotate(JSON.generate(complete.except(member))), http: 400, code: 'bad_request', detail: member.to_s)
    end
  end

  it 'answers 400 bad_request for a jwks that is not a JWK Set' do
    expect_problem(rotate(JSON.generate(complete.merge(jwks: 'key'))), http: 400, code: 'bad_request')
  end

  it 'answers a refused client assertion with 401 and the Kiosk-Client-Assertion challenge' do
    response = rotate(JSON.generate(complete))
    expect_problem(response, http: 401, code: 'unauthenticated')
    expect(response[1]['WWW-Authenticate']).to eq('Kiosk-Client-Assertion realm="https://demo.example"')
  end
end
