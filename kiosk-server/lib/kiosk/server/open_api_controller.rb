# frozen_string_literal: true

require "action_controller"
require "kiosk/server/open_api"
require "kiosk/server/schema_document"
require "kiosk/server/verb_controller"

module Kiosk
  module Server
    # `GET <endpoint>/openapi.json`: public, untolled, cached like `/schema`.
    class OpenApiController < VerbController
      # `?v=` is the origin's document version; the ETag is this document's bytes.
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
