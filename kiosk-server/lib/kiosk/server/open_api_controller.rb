# frozen_string_literal: true

require "action_controller"
require "kiosk/server/open_api"
require "kiosk/server/schema_document"
require "kiosk/server/verb_controller"

module Kiosk
  module Server
    # `GET <endpoint>/openapi.json` — the DERIVED OpenAPI description of this
    # origin's per-verb wire (T-068 slice 4, T-071 = C, ADR-0024).
    #
    # PUBLIC SINCE K-804 (Phil, 2026-08-19: «K-804 открывать»), and the whole
    # of what that decision moved is in this file:
    #
    #   * THE BEARER GATE IS GONE. Slice 4 gated it because «an anonymous read
    #     would hand out the catalog enumeration the per-verb wire orders its
    #     gates to withhold». Every clause of that sentence has since been
    #     retired for the SAME information in its other dress: `GET
    #     <endpoint>/schema` is public (T-094) and `/.well-known/api-catalog`
    #     hyperlinks every verb unauthenticated (T-093). This document is
    #     derived from the same in-process registry `schema` is derived from,
    #     so gating it withheld nothing and cost an explanation — which is
    #     precisely the inconsistency Phil objected to.
    #   * THE TOLL WENT WITH THE GATE, for the reason `schema`'s did: a toll is
    #     charged against an identity, and this endpoint no longer resolves
    #     one. It was tolled as the policy verb `:schema`; nothing tolls as
    #     `:schema` now, so that symbol left {Executor::VERBS}' predecessor
    #     `POLICY_VERBS`, which was deleted with it.
    #   * THE CACHE POLICY CAME IN THEIR PLACE. `public`, a strong `ETag`, a
    #     `304` on `If-None-Match`, `max-age={Headers::SHORT_MAX_AGE}` at the
    #     bare path and a year at `?v=<digest>` — the same treatment `schema`
    #     gets, from the same seam ({WireController#render_public_document}),
    #     so the two cannot drift apart again.
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
