# frozen_string_literal: true

# Engine wires up the route.

require "action_controller"
require "kiosk/server/events_ticket"
require "kiosk/server/identity_resolution"
require "kiosk/server/headers"

module Kiosk
  module Server
    # POST <endpoint>/events/ticket — mint a single-use connect ticket for the
    # event stream (spec Section 8.5.3).
    #
    # UNTOLLED, like every auth-plane endpoint except registration: it buys no
    # operator work, it is one signature over four claims, and tolling the one
    # call a client makes because its runtime cannot send a header would price
    # the runtime rather than the consumption.
    #
    # Authenticated by the ORDINARY chain — the same {IdentityResolution.resolve}
    # every verb uses — so a ticket can only ever speak for a caller that could
    # already have opened the socket with its header. It adds no authority; it
    # moves an existing one into a form a receive-only client can present.
    class EventsTicketController < ::ActionController::API
      def create
        identity = Kiosk::Server::IdentityResolution.resolve(request)
        Kiosk::Server::Headers.add_to(response.headers)

        return render(json: unauthorized_body, status: :unauthorized) unless identity

        render json: {
          ticket: Kiosk::Server::EventsTicket.mint(identity),
          expires_in: Kiosk::Server::EventsTicket::TTL_SECONDS,
        }
      end

      private

      # The wire's existing vocabulary — this endpoint introduces no new code,
      # and `unauthorized` is what every other unauthenticated call answers.
      def unauthorized_body
        {
          error: {
            code: "unauthorized",
            message: "present a bearer token this operator issued",
          },
        }
      end
    end
  end
end
