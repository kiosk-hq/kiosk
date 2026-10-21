# frozen_string_literal: true

require 'action_controller'

module Kiosk
  module Server
    # GET <endpoint>/.well-known/jwks.json — the current signing key, and the previous one while it is set.
    class JwksController < ::ActionController::API
      def show
        Kiosk::Server::Headers.add_to(response.headers)
        render json: Kiosk::Server::Jwks.build(keys: Kiosk.configuration.signing_keys)
      end
    end
  end
end
