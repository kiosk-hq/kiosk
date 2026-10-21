# frozen_string_literal: true

# The sentences the engine puts on the wire for a malformed request.
#
# A missing field reads `missing field: <name>`, the house sentence the demos
# use too. A body that is not JSON reads `invalid JSON body`. Neither carries a
# Ruby exception's message (`key not found: :public_key`) or a library's
# wording (`unexpected token …`).
#
# Dispatch is via `ActionController::Metal.action(...)`: a plain Rack app, no
# Rails host and no database.

require 'rack/mock'
require 'json'

module WireWordingSpec
  # Ruby-side leaks: `KeyError#message`, the json gem's parser wording, and an
  # object rendered by `to_s`. None of them may appear in a detail.
  RUBY_LEAKS = [/key not found/, /unexpected token/, /#</].freeze

  def wire_user_idp(identity)
    idp = Class.new do
      def initialize(identity) = @identity = identity
      def verify(_request) = @identity
    end
    Kiosk.configure { |c| c.user_idp = idp.new(identity) }
  end

  def call_auth(action, raw_body)
    env = Rack::MockRequest.env_for(
      "https://provider.example/kiosk/auth/#{action}",
      method: 'POST', input: raw_body, 'CONTENT_TYPE' => 'application/json'
    )
    status, headers, body = Kiosk::Server::AuthController.action(action).call(env)
    raw = +''
    body.each { |chunk| raw << chunk }
    [status, headers, raw.empty? ? {} : JSON.parse(raw, symbolize_names: true)]
  end

  # The media type of a problem document, the flat `code` an assistant
  # branches on, and the exact `detail`.
  def expect_detail(status, headers, body, detail)
    expect(status).to eq(400)
    expect(headers['Content-Type']).to include('application/problem+json')
    expect(body[:code]).to eq('bad_request')
    expect(body[:detail]).to eq(detail)
  end

  def expect_no_ruby(body)
    RUBY_LEAKS.each { |leak| expect(body[:detail]).not_to match(leak) }
  end
end

RSpec.shared_context 'with a provider origin for wire wording' do
  include WireWordingSpec

  let(:user_id) { '11111111-1111-1111-1111-111111111111' }

  before do
    Kiosk.configure do |c|
      c.issuer      = 'https://provider.example'
      c.signing_key = Kiosk::Server::SigningKey.generate
      c.roles       = %i[customer]
    end
  end
end

RSpec.describe Kiosk::Server::Errors do
  describe 'the malformed-request sentences on the wire' do
    include_context 'with a provider origin for wire wording'

    describe 'POST /kiosk/auth/rotate' do
      it 'names the absent field and not the Ruby exception when new_client_assertion is omitted' do
        body = { client_assertion_type: Kiosk::Server::ClientAssertion::TYPE, client_assertion: 'x',
                 jwks: { keys: [Kiosk::Server::AssistantKey.to_jwk(agent_key.public_key)] } }
        status, headers, body = call_auth(:rotate, JSON.generate(body))
        expect_detail(status, headers, body, 'missing field: new_client_assertion')
        expect_no_ruby(body)
      end

      it "answers a body that is not JSON with this protocol's own sentence" do
        status, headers, body = call_auth(:rotate, 'notjson')
        expect_detail(status, headers, body, 'invalid JSON body')
        expect_no_ruby(body)
        expect(body[:hint]).to eq(Kiosk::Server::Errors::MALFORMED_JSON_HINT)
      end
    end

    describe 'POST /kiosk/auth/claim' do
      it 'names the absent field when client_assertion is omitted' do
        body = { code: 'c', client_assertion_type: Kiosk::Server::ClientAssertion::TYPE }
        status, headers, body = call_auth(:claim, JSON.generate(body))
        expect_detail(status, headers, body, 'missing field: client_assertion')
        expect_no_ruby(body)
      end
    end

    # Behind the human's own session.
    describe 'POST /kiosk/auth/unlink' do
      it 'names the absent field when agent_id is omitted' do
        wire_user_idp(build_identity(actor: 'human', agent_id: nil, user_id: user_id))
        status, headers, body = call_auth(:unlink, JSON.generate({}))
        expect_detail(status, headers, body, 'missing field: agent_id')
        expect_no_ruby(body)
      end
    end

    describe 'Kiosk::Server::Errors.missing_field' do
      it 'names the KEY of a rescued KeyError, never its message' do
        err = begin
          {}.fetch(:public_key)
        rescue KeyError => e
          e
        end
        expect(err.message).to include('key not found')
        expect(described_class.missing_field(err).message).to eq('missing field: public_key')
      end

      it 'accepts a bare field name too, so a site with no exception can use it' do
        expect(described_class.missing_field('agent_id').message).to eq('missing field: agent_id')
      end

      it 'falls back to plain words — never to `message` — for a KeyError carrying no key' do
        built = described_class.missing_field(KeyError.new('key not found: :smuggled'))
        expect(built.message).to eq('request is missing a required field')
        expect(built.message).not_to include('smuggled')
      end
    end

    describe 'Kiosk::Server::Errors.malformed_json' do
      it 'is the whole detail, with the recovery sentence in the hint' do
        built = described_class.malformed_json
        expect(built.message).to eq('invalid JSON body')
        expect(built.hint).to eq(Kiosk::Server::Errors::MALFORMED_JSON_HINT)
      end

      it 'lets a site narrow the hint without touching the detail' do
        built = described_class.malformed_json(hint: "a query's arguments are in the query string.")
        expect(built.message).to eq('invalid JSON body')
        expect(built.hint).to eq("a query's arguments are in the query string.")
      end
    end

    describe 'Kiosk::Server::Errors.rescued_wire' do
      it 'words the refusal itself and names the verb, so nothing of the exception travels' do
        built = described_class.rescued_wire('bad_request', verb: 'strict')
        expect(built[:code]).to eq('bad_request')
        expect(built[:message]).to eq('verb "strict" rejected the request as malformed')
        expect(built[:hint]).to eq(Kiosk::Server::Errors::RESCUED_HINTS.fetch('bad_request'))
      end

      it 'says `this verb` when the dispatch name is unknown, rather than rendering nil' do
        expect(described_class.rescued_wire('not_found')[:message])
          .to eq('this verb found no such record')
        expect(described_class.rescued_wire('not_found', verb: '')[:message])
          .to eq('this verb found no such record')
      end

      # The rescue seam reaches this builder for every code STATUS_CODES can
      # decide. A code it cannot word would be a KeyError, so a 500, at request time.
      it 'words every code the rescue seam can decide, and invents none' do
        reachable = Kiosk::Server::Errors::STATUS_CODES.values.uniq.sort
        expect(Kiosk::Server::Errors::RESCUED_DETAILS.keys.sort).to eq(reachable)
        expect(Kiosk::Server::Errors::RESCUED_HINTS.keys.sort).to eq(reachable)
      end

      it 'carries no Ruby, no library and no exception wording in any entry' do
        Kiosk::Server::Errors::STATUS_CODES.values.uniq.each do |code|
          built = described_class.rescued_wire(code, verb: 'v')
          expect(built[:message]).not_to be_empty
          expect(built[:hint]).not_to be_empty
          WireWordingSpec::RUBY_LEAKS.each do |leak|
            expect(built[:message]).not_to match(leak)
            expect(built[:hint]).not_to match(leak)
          end
        end
      end
    end
  end
end
