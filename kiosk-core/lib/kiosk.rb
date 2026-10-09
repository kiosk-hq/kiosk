# frozen_string_literal: true

# kiosk-core — foundation for the Kiosk framework (https://kiosk.tech).

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
require "kiosk/kyc_providers/base"

module Kiosk
  # Serialises the first build of {configuration}, so racing threads never
  # each build one and lose settings written on a discarded copy.
  CONFIGURATION_MUTEX = Mutex.new

  def self.configure
    yield(configuration)
  end

  def self.configuration
    @configuration ||
      CONFIGURATION_MUTEX.synchronize { @configuration ||= Configuration.new }
  end

  CURRENT_ISSUER_KEY = :kiosk_current_issuer

  # The origin of the request being served, or the configured issuer outside one.
  def self.current_issuer
    Thread.current[CURRENT_ISSUER_KEY] || configuration.issuer
  end

  def self.with_issuer(issuer)
    previous = Thread.current[CURRENT_ISSUER_KEY]
    Thread.current[CURRENT_ISSUER_KEY] = issuer
    yield
  ensure
    Thread.current[CURRENT_ISSUER_KEY] = previous
  end

  def self.reset!
    CONFIGURATION_MUTEX.synchronize { @configuration = Configuration.new }
  end
end
