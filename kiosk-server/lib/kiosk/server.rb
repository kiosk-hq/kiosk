# frozen_string_literal: true

# kiosk-server: the Rails engine, its wire, auth and discovery controllers, and
# the install generator. See https://kiosk.tech.

require 'kiosk'
require 'active_record'
require 'action_dispatch/routing'
require 'active_support/core_ext' # the core extensions a Rails host loads, which the engine's code uses
require 'zeitwerk'

Zeitwerk::Loader.for_gem_extension(Kiosk).setup

module Kiosk
  module Server
  end

  # The user id and role of the principal the wire resolved.
  def self.current_user_id = Server::SessionContext.identity.user_id
  def self.current_role    = Server::SessionContext.identity.role
end

Kiosk::Configuration.include(Kiosk::Server::ConfigurationExtension)
ActionDispatch::Routing::Mapper.include(Kiosk::Server::Routing)
# Rails registers an engine when its class is defined.
Kiosk::Server::Engine
