# frozen_string_literal: true

# kiosk-server loaded, a host base controller, and verbs declared the way an
# operator declares them: what the in-process executor and origin specs need.
require 'kiosk/server'
require 'action_controller'

# The engine's controllers, which a Rails host autoloads.
Zeitwerk::Loader.new.tap do |loader|
  loader.push_dir(Kiosk::Server::Engine.root.join('app/controllers').to_s)
  loader.setup
end

# The host application's base controller. An assistant's verb call carries no
# CSRF token, so the mixin must skip forgery protection.
class ApplicationController < ActionController::Base
  protect_from_forgery with: :exception
end

module KioskServerSpecSupport
  # Both schemas a verb must declare. The open input schema lets a fixture take
  # any argument; a spec about the input contract passes its own.
  REQUIRED_MACROS = { input_schema: { type: 'object' }, output_schema: true }.freeze

  def declare_query(name, **macros, &body)
    declare_verb(:query, name, macros, body || -> { render json: [] })
  end

  def declare_action(name, **macros, &body)
    declare_verb(:action, name, macros, body || -> { render json: {} })
  end

  def declare_verb(verb_kind, name, macros, body)
    macros = { description: "the #{name} verb" } if macros.empty?
    macros = REQUIRED_MACROS.merge(macros)

    Class.new(ApplicationController) do
      include Kiosk::Handler

      kind verb_kind
      macros.each { |macro, value| public_send(macro, value) }
      define_method(name.to_s, &body)
    end
  end

  # The routes `kiosk do` draws for these names; the same route set serves the calls.
  def kiosk_routes(queries: [], actions: [])
    ActionDispatch::Routing::RouteSet.new.tap do |routes|
      routes.draw do
        kiosk do
          queries(*queries)
          actions(*actions)
        end
      end
    end
  end

  # An origin with no database: registering and linking an assistant mints its token, nothing
  # revokes it, and a verb's session runs on `connection`.
  def serve_wire_on(connection)
    Kiosk.configure do |c|
      c.issuer           = 'https://provider.example'
      c.signing_key      = Kiosk::Server::SigningKey.generate
      c.revocation_store = instance_double(Kiosk::Server::RevocationStores::ActiveRecord, revoked?: false)
    end
    link_assistants_without_database
    allow(ActiveRecord::Base).to receive(:lease_connection).and_return(connection)
  end

  # Registering and linking an assistant keeps its client in memory, and its
  # token is bound to the registered key. No agent row is written.
  def link_assistants_without_database
    clients = {}
    register_clients_in(clients)
    allow(Kiosk::Server::AccountBinding).to receive(:bind!) do |agent_id:, user_id:, requested_role:|
      clients[agent_id] = clients.fetch(agent_id).with(user_id:, allowed_roles: [requested_role].compact)
    end
    issue_tokens_from(clients)
  end

  def register_clients_in(clients)
    allow(Kiosk::Server::ClientRegistration).to receive(:call) do |metadata|
      pem = Kiosk::Server::AssistantKey.to_pem(Kiosk::Server::AssistantKey.from_jwks(metadata['jwks']))
      id  = "a-#{clients.size + 1}"
      clients[id] = Kiosk::Server::Client.new(id:, user_id: nil, public_key_pem: pem, allowed_roles: [], issued_at: 0)
    end
  end

  # The engine's agent-IdP verifies as it does in production; it mints from `clients`.
  def issue_tokens_from(clients)
    allow(Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp).to receive(:new).and_wrap_original do |original, *args|
      original.call(*args).tap do |idp|
        allow(idp).to receive(:issue) do |agent_id:, role:|
          client = clients.fetch(agent_id)
          claims = { sub: client.user_id, agent_id:, role:, cnf: { jkt: client.thumbprint } }.compact
          Kiosk::Server::JwtIssuer.issue(claims:, audience: Kiosk.current_issuer)
        end
      end
    end
  end

  def build_identity(actor: 'agent', **overrides)
    defaults = { user_id: 'u-1', role: 'customer', actor: actor, agent_id: actor == 'agent' ? 'a-1' : nil, claims: {} }
    Kiosk::Identity.new(**defaults, **overrides)
  end
end

RSpec.configure do |config|
  config.include KioskServerSpecSupport

  config.before do
    Kiosk::Server::Actions.reset!
    Kiosk::Server::Queries.reset!
  end
end
