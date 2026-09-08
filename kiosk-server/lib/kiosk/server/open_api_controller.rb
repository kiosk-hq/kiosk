# frozen_string_literal: true

require "action_controller"
require "kiosk/server/open_api"
require "kiosk/server/schema_document"
require "kiosk/server/verb_controller"

module Kiosk
  module Server
    # `GET <endpoint>/openapi.json` — the DERIVED OpenAPI description of this
    # origin's per-verb wire.
    #
    # IT IS PUBLIC, and the three consequences of that are the whole of this
    # file:
    #
    #   * NO BEARER GATE. This document is derived from the same in-process
    #     registry `GET <endpoint>/schema` is derived from; `schema` is itself
    #     public and `/.well-known/api-catalog` hyperlinks every verb
    #     unauthenticated, so a gate here would withhold nothing that is not
    #     already one anonymous GET away, and would cost an explanation.
    #   * NO TOLL, for the reason `schema` carries none: a toll is charged
    #     against an identity, and this endpoint resolves none.
    #   * A CACHE POLICY IN THEIR PLACE. `public`, a strong `ETag`, a `304` on
    #     `If-None-Match`, `max-age={Headers::SHORT_MAX_AGE}` at the bare path
    #     and a year at `?v=<digest>` — the same treatment `schema` gets, from
    #     the same seam ({WireController#render_public_document}), so the two
    #     cannot drift apart.
    #
    # WHAT IT STILL INHERITS from {VerbController}/{WireController}: the RFC
    # 9457 problem-document seam, so an unexpected refusal here is shaped like
    # every other refusal on this origin. The inherited verb-dispatch actions
    # play no part — `show` is overridden below, `create` is not routed here.
    #
    # PROVISIONAL — see {OpenApi}. Deleting the derived renderer is this file,
    # `open_api.rb`, one route line in the engine and one `item` in
    # {WellKnown.api_catalog}. Keep it that way.
    class OpenApiController < VerbController
      # GET <endpoint>/openapi.json
      #
      # `?v=` is compared against {SchemaDocument.digest} — the ORIGIN's
      # document version, which moves on any deploy that moves either derived
      # document — while the `ETag` is this document's own bytes. {OpenApi}
      # says why the two are different values.
      def show
        render_public_document(
          OpenApi.json(base_url: request.base_url),
          version:      SchemaDocument.digest,
          etag:         OpenApi.etag(base_url: request.base_url),
          content_type: OpenApi::CONTENT_TYPE,
        )
      end
    end
  end
end
