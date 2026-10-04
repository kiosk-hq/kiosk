# frozen_string_literal: true

require "rack/request"

module Kiosk
  module Server
    # Sets `Kiosk.current_issuer` for the request: its origin when the operator
    # serves it (`c.issuer` or one of `c.additional_origins`), else `c.issuer`.
    # The {Engine} installs it beside {HeadersMiddleware}; a plain Rack app
    # `use`s it.
    class IssuerMiddleware
      def initialize(app)
        @app = app
      end

      def call(env)
        issuer = Kiosk.configuration.issuer_for(::Rack::Request.new(env).base_url)
        Kiosk.with_issuer(issuer) { @app.call(env) }
      end
    end
  end
end
