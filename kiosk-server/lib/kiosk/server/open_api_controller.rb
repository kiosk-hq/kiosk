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
    #   * IDENTITY FIRST. Bearer. This is now the ONE surface still gated for a
    #     reason the rest of the fleet retired: `GET <endpoint>/schema` went
    #     PUBLIC in T-094 (the catalogue is not a secret, and it is a static
    #     answer), and `/.well-known/api-catalog` hyperlinks every verb
    #     unauthenticated (T-093). This document describes the SAME verbs, so
    #     the enumeration argument that gated it in slice 4 no longer holds
    #     here either — but Phil has not been asked about this endpoint, and
    #     rule 2 says an undecided conflict is filed, not picked. It is filed:
    #     **K-804**. Until it is answered the gate STAYS. Do not "make it
    #     consistent" in passing.
    #   * THE SAME TOLL. `:schema`, via {WireController#toll!} — it renders the
    #     same catalog from the same registry, and while this spelling costs an
    #     identity, a policy pricing it must still be able to. (The canonical
    #     `schema` endpoint pays no toll any more: it has no identity to charge
    #     and costs the origin nothing to serve.)
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
        # Tolled as the POLICY verb `:schema` — it renders the same catalog, so
        # an untolled second spelling of it would be a way to read around the
        # price. But the FINGERPRINT binds to this call's own path segment, not
        # to `schema`'s: §3.4 digests `"<METHOD> <verb>"`, and passing
        # `verb: "schema"` here would make one solved proof spendable on both
        # endpoints — a discount nobody decided on.
        toll!(identity: identity, command: :schema, name: "openapi.json", body: {})

        render_wire_body(
          OpenApi.build(base_url: request.base_url),
          status:       :ok,
          content_type: OpenApi::CONTENT_TYPE,
        )
      end
    end
  end
end
