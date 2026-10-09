# frozen_string_literal: true

require "action_controller"
require "kiosk/server/jwks"
require "kiosk/server/headers"

module Kiosk
  module Server
    # GET <endpoint>/.well-known/jwks.json — the public signing key.
    class JwksController < ::ActionController::API
      def show
        Kiosk::Server::Headers.add_to(response.headers)
        render json: Kiosk::Server::Jwks.build(keys: [Kiosk.configuration.signing_key])
      end
    end
  end
end
