# frozen_string_literal: true

module Kiosk
  module Server
    class AgentsRegistrationController < ::ActionController::API
      def create
        body   = JSON.parse(request.raw_post, symbolize_names: true)
        result = AgentRegistration.call(
          name: body.fetch(:name), public_key_pem: body.fetch(:public_key), role: body.fetch(:role),
        )
        Kiosk::Server::Headers.add_to(response.headers)
        render json: result, status: :created
      rescue KeyError => e
        render_error(Errors::BadRequest.new("missing field: #{e.message}"))
      rescue Errors::Base => e
        render_error(e)
      end

      private

      def render_error(err)
        Kiosk::Server::Headers.add_to(response.headers)
        render json: err.to_envelope, status: err.http_status
      end
    end
  end
end
