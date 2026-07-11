# frozen_string_literal: true

module Kiosk
  module Server
    # Helper for composing the three response headers kiosk-server sends on
    # every `/kiosk/*` response (the API-version handshake).
    module Headers
      # Mutate a Rack headers hash to add the three Kiosk headers.
      # The server version defaults to {Kiosk::Server::VERSION}; callers
      # may override (e.g. tests).
      def self.add_to(headers, server_version: Kiosk::Server::VERSION)
        headers[Kiosk::Protocol::HEADER_SERVER_VERSION] = server_version
        headers[Kiosk::Protocol::HEADER_API_VERSION]    = Kiosk::Protocol::API_VERSION
        headers[Kiosk::Protocol::HEADER_MIN_CLIENT]     = Kiosk::Protocol::MIN_CLIENT
        headers
      end

      # Build a fresh headers hash with the three Kiosk headers set.
      def self.build(server_version: Kiosk::Server::VERSION)
        add_to({}, server_version: server_version)
      end
    end
  end
end
