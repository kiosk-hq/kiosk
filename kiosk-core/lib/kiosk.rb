# frozen_string_literal: true

# kiosk-core — foundation for the Kiosk framework.
# See https://kiosk.tech and the design spec for full architecture.

require "kiosk/version"
require "kiosk/protocol"
require "kiosk/guc"
require "kiosk/configuration"
require "kiosk/identity"
require "kiosk/mandate"
require "kiosk/event"

require "kiosk/agent_identity_providers/base"
require "kiosk/user_identity_providers/base"
require "kiosk/payment_providers/base"
require "kiosk/credential_brokers/base"
require "kiosk/notification_adapter/base"

module Kiosk
  # Configure Kiosk for the host application.
  #
  # @example
  #   Kiosk.configure do |c|
  #     c.user_model     = "User"
  #     c.user_id_type   = :uuid
  #     c.user_id_column = :id
  #     c.user_idp       = MyApp::KioskAdapters::Devise.new
  #     c.agent_idp      = Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp.new
  #     c.guc_namespace  = "app"
  #     c.roles          = %i[customer master support]
  #     c.issuer         = "https://api.acme.example"
  #   end
  def self.configure
    yield(configuration)
  end

  # Access the active configuration. Creates a default one on first read.
  def self.configuration
    @configuration ||= Configuration.new
  end

  # Reset the configuration to a fresh default instance. Primarily for tests.
  def self.reset!
    @configuration = Configuration.new
  end
end
