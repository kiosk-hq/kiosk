# frozen_string_literal: true

# Needs kiosk-server, which only a Rails host carries; this gem does not depend
# on it, so a test helper requires this file explicitly.

require 'json'
require 'openssl'
require 'rack/mock'
require 'uri'
require 'kiosk/server'
require 'kiosk/test_helpers/wire'
require 'kiosk/test_helpers/dpop'

module Kiosk
  module TestHelpers
    # Calls a verb of the booted app through its route, in this process, as an
    # assistant does: one linked to the principal's account, as a person links
    # one, and paying any proof-of-work toll. A caller with no identity sends no
    # token.
    class InProcessWire
      # `app` defaults to the Rails application, middleware included.
      def initialize(app: nil)
        @app = app
      end

      # The verb's answer, or the Kiosk error its refusal names.
      def call(name, kind:, params:, identity:)
        credential = credential_for(identity) if identity
        response   = request(name, kind, params, credential)
        challenges = toll_challenges(response)
        response   = request(name, kind, params, credential, Wire.solve(challenges)) if challenges
        answer(response)
      end

      private

      def app = @app || ::Rails.application

      def request(name, kind, params, credential, proofs = nil)
        query = kind.to_sym == :query
        url = "#{Kiosk.current_issuer.to_s.chomp('/')}#{Kiosk.configuration.mount_path}/#{name}"
        env = credentials(credential, query ? 'GET' : 'POST', url, proofs)
        return Rack::MockRequest.new(app).get(query_url(url, params), env) if query

        Rack::MockRequest.new(app).post(url, env.merge(input: JSON.generate(params), 'CONTENT_TYPE' => 'application/json'))
      end

      # The access token with a DPoP proof its key signs for this request.
      def credentials(credential, method, url, proofs)
        env = credential ? Dpop.env(credential.token, credential.key, method:, url:) : {}
        env['HTTP_KIOSK_POW'] = JSON.generate(proofs) if proofs
        env
      end

      def query_url(url, params) = params.empty? ? url : "#{url}?#{URI.encode_www_form(params)}"

      # The token and key of an assistant registered and linked to the principal for this call.
      def credential_for(identity)
        key    = Dpop.generate_key
        client = Kiosk::Server::AccountBinding.bind!(agent_id: register(key).id, user_id: identity.user_id,
                                                     requested_role: identity.role)
        token  = Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp.new.issue(agent_id: client.id, role: client.role)
        Wire::DpopCredential.new(token:, key:)
      end

      # Registers the key as a client, and pays the registration toll if the origin asks for one.
      def register(key)
        metadata = { 'jwks' => { 'keys' => [Kiosk::Server::AssistantKey.to_jwk(key)] } }
        Kiosk::Server::ClientRegistration.call(metadata)
      rescue Kiosk::Server::Errors::PowRequired => e
        header = JSON.generate(Wire.solve(JSON.parse(JSON.generate(e.challenges))))
        Kiosk::Server::ClientRegistration.call(metadata, pow: Kiosk::Server::PowGate.proofs_from_header(header))
      end

      def toll_challenges(response)
        problem = parse(response.body)
        return unless response.status == 402 && problem.is_a?(Hash) && problem['code'] == 'pow_required'

        problem['challenges']
      end

      def answer(response)
        body = parse(response.body)
        return body if response.successful?

        raise refusal(response.status, body)
      end

      def refusal(status, body)
        return RuntimeError.new("the origin answered #{status}: #{body.inspect}") unless problem?(body)

        Kiosk::Server::Errors::WireError.new(body['detail'], code: body['code'], hint: body['hint'])
      end

      def problem?(body) = body.is_a?(Hash) && Kiosk::Server::Errors::CODES.key?(body['code'])

      def parse(raw)
        raw.to_s.empty? ? nil : JSON.parse(raw)
      rescue JSON::ParserError
        raw
      end
    end
  end
end
