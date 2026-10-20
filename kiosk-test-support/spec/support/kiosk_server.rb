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

  # An origin with no database: linking an assistant mints its token, nothing
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

  # Linking an assistant mints its token and writes no agent row.
  def link_assistants_without_database
    allow(Kiosk::Server::AccountBinding).to receive(:bind!) do |user_id:, requested_role:, **|
      claims = { sub: user_id, agent_id: "a-#{user_id}", role: requested_role }.compact
      { access_token: Kiosk::Server::JwtIssuer.issue(claims: claims, audience: Kiosk.current_issuer) }
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
