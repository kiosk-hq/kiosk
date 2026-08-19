# frozen_string_literal: true

require "action_controller"
require "kiosk/server/open_api"
require "kiosk/server/verb_controller"

module Kiosk
  module Server
    # `GET <endpoint>/openapi.json` — the DERIVED OpenAPI description of this
    # origin's per-verb wire (T-068 slice 4, T-071 = C, ADR-0024).
    #
    # Six lines of controller on purpose. Everything that makes this endpoint
    # behave like the wire it describes is INHERITED from {VerbController}
    # rather than restated here, and that is deliberate:
    #
    #   * IDENTITY FIRST. Bearer, exactly like `GET <endpoint>/schema`. The
    #     document publishes the whole catalog — every verb name, every
    #     argument, every result shape — so serving it unauthenticated would
    #     hand an anonymous caller the enumeration slice 1 ordered its gates
    #     (401 before 404) specifically to withhold.
    #   * THE SAME TOLL. `:schema`, via {WireController#toll!} — it renders the
    #     same catalog from the same registry, and a policy pricing `schema`
    #     must not be walkable around by asking for the other spelling.
    #   * THE SAME FAILURE SHAPE. An RFC 9457 problem document under
    #     `application/problem+json`, from the seam {VerbController} already
    #     overrides. A second copy of that seam here is exactly the drift this
    #     whole slice is built to be incapable of.
    #
    # The inherited verb-dispatch actions (`show` is overridden below;
    # `create` is not routed at this controller) play no part.
    #
    # PROVISIONAL — see {OpenApi}. Deleting the derived renderer is this file,
    # `open_api.rb`, one route line in the engine and one `item` in
    # {WellKnown.api_catalog}. Keep it that way.
    class OpenApiController < VerbController
      # GET <endpoint>/openapi.json
      def show
        identity = resolve_identity!
        toll!(identity: identity, command: :schema, body: {})

        render_wire_body(
          OpenApi.build(base_url: request.base_url),
          status:       :ok,
          content_type: OpenApi::CONTENT_TYPE,
        )
      end
    end
  end
end
