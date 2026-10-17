# frozen_string_literal: true

# kiosk-server loaded, a host base controller, and verbs declared the way an
# operator declares them: what the in-process executor and origin specs need.
require 'kiosk/server'
require 'action_controller'

# The host application's base controller. A handler sub-dispatch never carries
# a CSRF token, so the mixin must skip forgery protection.
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
