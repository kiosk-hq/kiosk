# frozen_string_literal: true

require "digest"
require "json"
require "kiosk/server/actions"
require "kiosk/server/argument_decoder"
require "kiosk/server/errors"
require "kiosk/server/handler_mixin"
require "kiosk/server/queries"
require "kiosk/server/schema_document"
require "kiosk/server/well_known"

module Kiosk
  module Server
    # `GET <endpoint>/openapi.json`: an OpenAPI 3.1 rendering of the same
    # registries `/schema` renders, for tooling. `/schema` stays canonical;
    # nothing here may say what the descriptors do not.
    module OpenApi
      # 3.1: its Schema Objects are JSON Schema 2020-12, so descriptors embed verbatim.
      OPENAPI_VERSION = "3.1.0"

      JSON_SCHEMA_DIALECT = "https://json-schema.org/draft/2020-12/schema"

      CONTENT_TYPE = "application/vnd.oai.openapi+json;version=3.1"

      # No operation answers 405: the other method at a verb's path matches no route.
      METHOD_NOT_ALLOWED = "method_not_allowed"

      INFO_DESCRIPTION = <<~TEXT.strip
        A DERIVED description of this origin's Kiosk verbs, generated from the
        same registry `GET <endpoint>/schema` renders. `schema` is the
        canonical catalog and this document is a convenience for tooling; where
        the two could ever disagree, `schema` is right.

        Every verb is its own endpoint: a query is a GET whose arguments are in
        the query string, an action is a POST whose arguments are a JSON body.
        There is no third channel. This origin draws one route per verb with
        the method its kind requires and nothing else, so calling a verb with
        the other method matches no route and answers an ordinary 404 with no
        problem document and no `Allow`. Read the kind off this document, or
        off `GET <endpoint>/schema`, and dial the method it names.

        A success body is the verb's result and nothing else: no envelope, no
        `ok` flag, no `kind`. An error body is an RFC 9457 problem document
        served as `application/problem+json`; branch on its `code` member, not
        on the HTTP status alone.

        `limit` and `cursor` are reserved parameter names this wire always
        accepts on a query, whether or not the verb declares them, and they
        drive the cursor pagination of the specification's Section 8.4. A
        paginated answer is still a bare array: the next page's URI arrives in
        an RFC 8288 `Link` response header with `rel="next"`, and the count of
        matching rows in `X-Total-Count`.

        Normative specification: https://kiosk.tech/specification.html
      TEXT

      def self.build(base_url:, config: Kiosk.configuration)
        endpoint = base_url.to_s.chomp("/") + config.mount_path

        modules = Array(config.capabilities).map(&:to_s)
        schemas = { "Problem" => problem_schema }
        paths   = {}

        if modules.include?("schema")
          schemas.merge!(schema_components)
          paths["/schema"] = { get: schema_operation }
        end
        if modules.include?("pay")
          schemas.merge!(pay_components)
          paths["/pay"] = { post: pay_operation }
        end

        entries.each do |kind, descriptor|
          name = descriptor[:name].to_s
          schemas.merge!(components_for(descriptor[:output_schema], "#{name}.response"))
          if request_component?(kind, descriptor[:input_schema])
            schemas.merge!(components_for(descriptor[:input_schema], "#{name}.request"))
          end
          paths["/#{name}"] = { http_method(kind) => operation(kind, descriptor) }
        end

        {
          openapi:           OPENAPI_VERSION,
          jsonSchemaDialect: JSON_SCHEMA_DIALECT,
          info:              {
            title:       "#{WellKnown.site_name(config)} — Kiosk",
            version:     Kiosk::Protocol::API_VERSION,
            description: INFO_DESCRIPTION,
          },
          externalDocs:      {
            description: "The Kiosk specification (normative)",
            url:         "https://kiosk.tech/specification.html",
          },
          servers:           [{ url: endpoint, description: "This origin's Kiosk endpoint." }],
          security:          [{ bearerAuth: [] }],
          tags:              [
            { name: "wire",    description: "The protocol's own reserved endpoints." },
            { name: "queries", description: "Reads. GET, arguments in the query string." },
            { name: "actions", description: "Writes. POST, arguments in a JSON body." },
          ],
          paths:             paths,
          components:        {
            securitySchemes: { bearerAuth: bearer_scheme },
            parameters:      reserved_parameters,
            headers:         PAGINATION_HEADERS,
            responses:       problem_responses,
            schemas:         schemas,
          },
        }
      end

      # Unmemoized; the served bytes come from {.json}.
      def self.build_json(**kwargs)
        JSON.generate(build(**kwargs))
      end

      # Memoized per `[base_url, SchemaDocument.digest]`: `servers[0].url` names
      # the requesting origin, and every other input is in the catalog digest.
      DIGEST_LENGTH = 32

      class << self
        def json(base_url:, config: Kiosk.configuration)
          derive(base_url: base_url, config: config).fetch(:json)
        end

        def etag(base_url:, config: Kiosk.configuration)
          %("#{derive(base_url: base_url, config: config).fetch(:digest)}")
        end

        # Called from the engine's `to_prepare`.
        def reset!
          @memo = nil
          self
        end

        private

        def derive(base_url:, config:)
          key = [base_url.to_s, SchemaDocument.digest(config: config)]
          return @memo if @memo && @memo[:key] == key

          json = build_json(base_url: base_url, config: config)
          @memo = { key: key, json: json.freeze,
                    digest: Digest::SHA256.hexdigest(json)[0, DIGEST_LENGTH].freeze }.freeze
        end
      end

      # Sorted by name across both registries; one name is one kind.
      def self.entries
        (Queries.catalog.map { |d| [:query, d] } + Actions.catalog.map { |d| [:action, d] })
          .sort_by { |(_kind, descriptor)| descriptor[:name].to_s }
      end
      private_class_method :entries

      def self.http_method(kind) = kind == :query ? :get : :post
      private_class_method :http_method

      def self.operation(kind, descriptor)
        name = descriptor[:name].to_s
        op = {
          operationId: name,
          tags:        [kind == :query ? "queries" : "actions"],
        }
        op[:description] = descriptor[:description] unless descriptor[:description].nil?

        if kind == :query
          op[:parameters] = query_parameters(name, descriptor[:input_schema])
        else
          op[:requestBody] = request_body(name, descriptor[:input_schema])
        end

        op[:responses] = responses(kind, descriptor)
        op
      end
      private_class_method :operation

      def self.query_parameters(name, input_schema)
        properties = ArgumentDecoder.fetch(input_schema, :properties) || {}
        required   = Array(ArgumentDecoder.fetch(input_schema, :required)).map(&:to_s)
        declared   = properties.keys.map(&:to_s)
        base       = "#{name}.request"
        map        = ref_map(input_schema, base)

        parameters = properties.map do |property, schema|
          {
            name:     property.to_s,
            in:       "query",
            required: required.include?(property.to_s),
            # Explicit: some tools ignore the OAS defaults.
            style:    style_for(schema),
            explode:  true,
            schema:   rewrite_refs(schema, map, base),
          }
        end

        # `limit`/`cursor` are always accepted, so declare them unless the verb did.
        ArgumentDecoder::RESERVED.each_key do |reserved|
          next if declared.include?(reserved)

          parameters << { "$ref": "#/components/parameters/#{reserved}" }
        end

        parameters
      end
      private_class_method :query_parameters

      # OAS 3.1.1 §4.8.12.3: `deepObject` is for objects only.
      def self.style_for(schema)
        ArgumentDecoder.declared_type(schema) == "object" ? "deepObject" : "form"
      end
      private_class_method :style_for

      # Required only when the schema requires a property; an absent body reads as `{}`.
      def self.request_body(name, input_schema)
        {
          required: !Array(ArgumentDecoder.fetch(input_schema, :required)).empty?,
          content:  {
            "application/json" => { schema: { "$ref": "#/components/schemas/#{name}.request" } },
          },
        }
      end
      private_class_method :request_body

      def self.responses(kind, descriptor)
        name   = descriptor[:name].to_s
        output = descriptor[:output_schema]
        ok = {
          description: ArgumentDecoder.fetch(output, :description) || "The verb's result.",
          content:     {
            "application/json" => { schema: { "$ref": "#/components/schemas/#{name}.response" } },
          },
        }
        ok[:headers] = PAGINATION_HEADERS.keys.to_h { |h| [h, { "$ref": "#/components/headers/#{h}" }] } if kind == :query

        { "200" => ok }.merge(problem_refs)
      end
      private_class_method :responses

      # Hoists the schema's root `$defs` into `components/schemas` as
      # `<verb>.<slot>.<name>` and rewrites the `$ref`s to match.
      def self.components_for(schema, base)
        defs = ArgumentDecoder.fetch(schema, :"$defs")
        map  = ref_map(schema, base)

        body = schema.is_a?(::Hash) ? schema.reject { |key, _| key.to_s == "$defs" } : schema
        out  = { base => rewrite_refs(body, map, base) }
        return out unless defs.is_a?(::Hash)

        defs.each do |name, definition|
          out["#{base}.#{name}"] = rewrite_refs(definition, map, "#{base}.#{name}")
        end
        out
      end
      private_class_method :components_for

      def self.ref_map(schema, base)
        defs = ArgumentDecoder.fetch(schema, :"$defs")
        return {} unless defs.is_a?(::Hash)

        defs.keys.each_with_object({}) do |name, out|
          out["#/$defs/#{name}"] = "#/components/schemas/#{base}.#{name}"
        end
      end
      private_class_method :ref_map

      # Document-relative refs only; external ones are left alone.
      def self.rewrite_refs(node, map, base)
        case node
        when ::Hash
          node.each_with_object({}) do |(key, value), out|
            out[key] =
              if key.to_s == "$ref" && value.is_a?(::String) && value.start_with?("#")
                rewrite_ref(value, map, "#/components/schemas/#{base}")
              else
                rewrite_refs(value, map, base)
              end
          end
        when ::Array then node.map { |element| rewrite_refs(element, map, base) }
        else node
        end
      end
      private_class_method :rewrite_refs

      def self.rewrite_ref(ref, map, prefix)
        return prefix if ref == "#"

        hit = map.keys.find { |pointer| ref == pointer || ref.start_with?("#{pointer}/") }
        return "#{map.fetch(hit)}#{ref.delete_prefix(hit)}" if hit

        "#{prefix}#{ref.delete_prefix("#")}"
      end
      private_class_method :rewrite_ref

      # A query's input is a component only when a parameter points into it.
      def self.request_component?(kind, input_schema)
        kind == :action || contains_ref?(input_schema)
      end
      private_class_method :request_component?

      def self.contains_ref?(node)
        case node
        when ::Hash  then node.any? { |key, value| key.to_s == "$ref" || contains_ref?(value) }
        when ::Array then node.any? { |element| contains_ref?(element) }
        else false
        end
      end
      private_class_method :contains_ref?

      # The protocol's own endpoints (§8.3, §11.3), declared rather than derived.
      def self.schema_operation
        {
          operationId: "schema",
          tags:        ["wire"],
          description: "This origin's catalog: every query and action it publishes, " \
                       "with their descriptions and schemas. THE canonical surface " \
                       "description — this OpenAPI document is derived from it. " \
                       "PUBLIC: no credential is required. The MODULE set this origin " \
                       "serves is `capabilities` in /.well-known/kiosk.json.",
          # Public: opts out of the global `bearerAuth`.
          security:    [],
          responses:   {
            "200" => {
              description: "The catalog.",
              content:     {
                "application/json" => {
                  schema: { "$ref": "#/components/schemas/schema.response" },
                },
              },
            },
          }.merge(problem_refs),
        }
      end
      private_class_method :schema_operation

      def self.schema_components
        {
          "schema.response" => {
            type:                 "object",
            title:                "The `schema` catalog",
            properties:           {
              queries: { type: "array", items: { "$ref": "#/components/schemas/schema.descriptor" } },
              actions: { type: "array", items: { "$ref": "#/components/schemas/schema.descriptor" } },
            },
            required:             %w[queries actions],
            additionalProperties: false,
          },
          "schema.descriptor" => {
            type:       "object",
            title:      "One verb descriptor",
            properties: {
              name:           { type: "string", pattern: HandlerMixin::NAME_PATTERN.source },
              description:    { type: %w[string null],
                                description: "The verb's SEMANTICS, in prose. Authoritative." },
              reach:          { type: "string", enum: HandlerMixin::REACHES.map(&:to_s),
                                description: "Whose rows this verb may touch (spec §7.2). " \
                                             "`principal` is the default and the norm; the " \
                                             "other three are declared departures." },
              input_schema:   { type: "object",
                                description: "JSON Schema (draft 2020-12) for this verb's inputs. " \
                                             "The authoritative input contract." },
              output_schema:  { type: "object",
                                description: "JSON Schema (draft 2020-12) for what this verb returns." },
              example_params: { description: "Example inputs an assistant can copy as a " \
                                             "starting call. It ILLUSTRATES `input_schema` " \
                                             "and is not the contract: where the two " \
                                             "disagree, the schema is right." },
              example_row:    { description: "Example of one result element — a " \
                                             "representative row for a query, or the return " \
                                             "value for an action. It ILLUSTRATES " \
                                             "`output_schema` and is not the contract." },
            },
            required:   %w[name description reach input_schema output_schema],
          },
        }
      end
      private_class_method :schema_components

      def self.pay_operation
        {
          operationId: "pay",
          tags:        ["wire"],
          description: "Settle an AP2 cart: submit the signed intent -> cart -> payment " \
                       "mandate chain. Answers 402 `payment_setup_required` when the " \
                       "identity has no card on file and 402 `payment_failed` when the " \
                       "charge did not settle — branch on the problem document's `code`.",
          requestBody: {
            required: true,
            content:  {
              "application/json" => {
                schema: { "$ref": "#/components/schemas/pay.request" },
              },
            },
          },
          responses:   {
            "200" => {
              description: "The settlement receipt.",
              content:     {
                "application/json" => {
                  schema: { "$ref": "#/components/schemas/pay.response" },
                },
              },
            },
          }.merge(problem_refs),
        }
      end
      private_class_method :pay_operation

      def self.pay_components
        jws = ->(what) { { type: "string", description: "Compact RS256 JWS: the signed #{what} mandate." } }
        {
          "pay.request"  => {
            type:                 "object",
            title:                "The AP2 mandate chain",
            properties:           {
              intent_mandate_jws:  jws.call("intent"),
              cart_mandate_jws:    jws.call("cart"),
              payment_mandate_jws: jws.call("payment"),
            },
            required:             %w[intent_mandate_jws cart_mandate_jws payment_mandate_jws],
            additionalProperties: false,
          },
          "pay.response" => {
            type:                 "object",
            title:                "Settlement receipt",
            properties:           {
              settlement_id:        { type: "string", description: "This origin's settlement row id." },
              psp_reference:        { type: "string", description: "The processor's own reference." },
              settled_amount_cents: { type: "integer" },
              currency:             { type: "string" },
            },
            required:             %w[settlement_id psp_reference settled_amount_cents currency],
            additionalProperties: false,
          },
        }
      end
      private_class_method :pay_components

      def self.problem_refs
        problem_statuses.each_with_object({}) do |status, out|
          out[status.to_s] = { "$ref": "#/components/responses/problem#{status}" }
        end
      end
      private_class_method :problem_refs

      def self.bearer_scheme
        {
          type:         "http",
          scheme:       "bearer",
          bearerFormat: "JWT",
          description:  "An access token from the kiosk-pop auth plane " \
                        "(`POST <endpoint>/auth/register` or `/auth/login`), " \
                        "verifiable against `<endpoint>/.well-known/jwks.json`.",
        }
      end
      private_class_method :bearer_scheme

      # §8.4. OAS 3.1 §4.8.21.1: a Header Object carries no `name` or `in`.
      PAGINATION_HEADERS = {
        "Link"          => {
          description: "RFC 8288 (Web Linking). Carries `rel=\"next\"` when this answer was " \
                       "TRUNCATED: fetch that target URI verbatim for the following page. " \
                       "ABSENT means this is the last (or only) page. The target repeats this " \
                       "request with the reserved `cursor` parameter set to an OPAQUE token — " \
                       "follow it, do not parse it.",
          required:    false,
          schema:      { type: "string" },
        },
        "X-Total-Count" => {
          description: "How many rows MATCH the query across all pages — not how many this " \
                       "response carries. A DE-FACTO CONVENTION, not a standard: no RFC " \
                       "defines it. Omitted when the operator does not know the total, so " \
                       "treat it as advisory and never as a loop bound.",
          required:    false,
          schema:      { type: "integer", minimum: 0 },
        },
      }.freeze

      def self.reserved_parameters
        {
          "limit"  => {
            name:        "limit",
            in:          "query",
            required:    false,
            style:       "form",
            explode:     true,
            description: "Maximum rows in one page. The operator MAY clamp it. " \
                         "Reserved: always accepted, never required to be declared.",
            schema:      { type: ArgumentDecoder::RESERVED.fetch("limit"), minimum: 1 },
          },
          "cursor" => {
            name:        "cursor",
            in:          "query",
            required:    false,
            style:       "form",
            explode:     true,
            description: "The OPAQUE `next` token from the previous page, echoed back " \
                         "verbatim. Never parse or construct one. " \
                         "Reserved: always accepted, never required to be declared.",
            schema:      { type: ArgumentDecoder::RESERVED.fetch("cursor") },
          },
        }
      end
      private_class_method :reserved_parameters

      def self.problem_statuses
        Errors::CODES.reject { |code, _| code == METHOD_NOT_ALLOWED }.values.uniq.sort
      end
      private_class_method :problem_statuses

      def self.problem_responses
        problem_statuses.each_with_object({}) do |status, out|
          codes = Errors::CODES.select { |_, value| value == status }.keys
          response = {
            description: "#{codes.join(" · ")} — see the problem document's `code`.",
            content:     {
              Errors::PROBLEM_CONTENT_TYPE => {
                schema: { "$ref": "#/components/schemas/Problem" },
              },
            },
          }
          # The two 402 gates differ by challenge header (RFC 7235).
          if status == 402
            response[:headers] = {
              "WWW-Authenticate" => {
                description: "`Kiosk-PoW realm=\"<issuer>\"` for a proof-of-work toll, " \
                             "`Payment realm=\"<issuer>\", method=\"ap2\"` for payment setup.",
                schema:      { type: "string" },
              },
            }
          end
          out["problem#{status}"] = response
        end
      end
      private_class_method :problem_responses

      def self.problem_schema
        {
          type:        "object",
          title:       "Problem document (RFC 9457)",
          description: "Every error on this wire. Branch on `code`.",
          properties:  {
            type:       {
              type: "string", format: "uri",
              description: "`#{Errors::PROBLEM_TYPE_BASE}<code>` — an IDENTIFIER for the " \
                           "problem type, not a document to fetch. Never branch on it.",
            },
            title:      { type: "string",
                          description: "A constant summary of the problem TYPE, not of this incident." },
            status:     { type: "integer", description: "The HTTP status, repeated." },
            detail:     { type: "string",  description: "What went wrong THIS time." },
            code:       { type: "string", enum: Errors::CODES.keys,
                          description: "THE BRANCH POINT: the closed Kiosk error vocabulary." },
            hint:       { type: "string",
                          description: "How to recover, when the error knows. Present on the errors " \
                                       "a caller can do something about." },
            challenges: { type: "array",
                          description: "On a `pow_required` 402: the proof-of-work challenges to " \
                                       "solve and echo back in the `Kiosk-PoW` request header." },
          },
          required:    %w[type title status code],
        }
      end
      private_class_method :problem_schema
    end
  end
end
