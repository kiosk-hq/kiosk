# frozen_string_literal: true

# kiosk-core — foundation for the Kiosk framework.
# See https://kiosk.tech and its normative specification
# (https://kiosk.tech/specification.html) for full architecture.

require "kiosk/version"
require "kiosk/protocol"
require "kiosk/guc"
require "kiosk/configuration"
require "kiosk/identity"
require "kiosk/mandate"
require "kiosk/uuid_check"

require "kiosk/agent_identity_providers/base"
require "kiosk/user_identity_providers/base"
require "kiosk/payment_providers/base"

module Kiosk
  # Serialises the FIRST touch of the lazy {configuration} slot below.
  #
  # `@configuration ||= Configuration.new` would be a read, an allocation and a
  # write with no lock between them: N threads racing the first read each build
  # a Configuration of their own, the last write discards the others, and every
  # setting written on a discarded copy is silently lost. The lazy store slots
  # in kiosk-server's configuration extension are the same shape one level
  # down, and this is the object they hang off — so a race here loses all of
  # them at once rather than one store.
  #
  # The read path stays lock-free: the mutex is entered only while the ivar is
  # still unset, so a settled slot costs one ivar read and nothing else. This
  # one is on every path in every gem — `Kiosk.configuration` is how the whole
  # framework reaches its settings.
  #
  # Nothing re-enters it. `Configuration#initialize` assigns plain ivars and
  # reads no configuration, and no Configuration extension in this workspace
  # overrides `initialize`, so the lock cannot be taken twice on one thread
  # (a Ruby Mutex is not reentrant and would raise ThreadError).
  CONFIGURATION_MUTEX = Mutex.new

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
  # The first read is serialised on {CONFIGURATION_MUTEX} so exactly one
  # Configuration is ever built; every read after that is lock-free.
  def self.configuration
    @configuration ||
      CONFIGURATION_MUTEX.synchronize { @configuration ||= Configuration.new }
  end

  # Reset the configuration to a fresh default instance. Primarily for tests.
  # Takes the same lock as the first read, so a reset racing a first touch
  # settles one way or the other instead of interleaving inside it.
  def self.reset!
    CONFIGURATION_MUTEX.synchronize { @configuration = Configuration.new }
  end
end
