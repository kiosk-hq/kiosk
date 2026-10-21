# frozen_string_literal: true

require 'digest'
require 'json'

module Kiosk
  module Server
    # `GET <endpoint>/openapi.json`: an OpenAPI 3.1 rendering of the same
    # registries `/schema` renders, for tooling. `/schema` stays canonical;
    # nothing here may say what the descriptors do not.
    module OpenApi
      # 3.1: its Schema Objects are JSON Schema 2020-12, so descriptors embed verbatim.
      OPENAPI_VERSION = '3.1.0'

      JSON_SCHEMA_DIALECT = 'https://json-schema.org/draft/2020-12/schema'

      CONTENT_TYPE = 'application/vnd.oai.openapi+json;version=3.1'

      # A verb or topic name as a JSON Schema pattern, which is ECMA-262: it anchors with `^` and `$`.
      NAME_PATTERN = "^#{HandlerMixin::NAME_PATTERN.source.delete_prefix('\\A').delete_suffix('\\z')}$".freeze

      # No operation answers 405: the other method at a verb's path matches no route.
      METHOD_NOT_ALLOWED = 'method_not_allowed'

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
        accepts on a query. A query may declare `limit` to bound its page
        size; no verb declares `cursor`. The two names drive the cursor
        pagination of the specification's Section 8.4. A
        paginated answer is still a bare array: the next page's URI arrives in
        an RFC 8288 `Link` response header with `rel="next"`, and the count of
        matching rows in `X-Total-Count`.

        Normative specification: https://kiosk.tech/specification.html
      TEXT

      EXTERNAL_DOCS = {
        description: 'The Kiosk specification (normative)',
        url: 'https://kiosk.tech/specification.html'
      }.freeze

      TAGS = [
        { name: 'wire',    description: "The protocol's own reserved endpoints." },
        { name: 'queries', description: 'Reads. GET, arguments in the query string.' },
        { name: 'actions', description: 'Writes. POST, arguments in a JSON body.' }
      ].freeze

      def self.build(base_url:, config: Kiosk.configuration)
        endpoint = base_url.to_s.chomp('/') + config.mount_path
        schemas, paths = Wire.surface(Array(config.capabilities).map(&:to_s))
        Verbs.add_entries(schemas, paths)
        document(endpoint, config, paths, schemas)
      end

      def self.document(endpoint, config, paths, schemas)
        {
          openapi: OPENAPI_VERSION, jsonSchemaDialect: JSON_SCHEMA_DIALECT,
          info: info(config),
          externalDocs: EXTERNAL_DOCS,
          servers: [{ url: endpoint, description: "This origin's Kiosk endpoint." }],
          security: [{ dpopAuth: [] }],
          tags: TAGS,
          paths: paths,
          components: Wire.components(schemas)
        }
      end
      private_class_method :document

      def self.info(config)
        {
          title: "#{WellKnown.site_name(config)} — Kiosk",
          version: Kiosk::Protocol::API_VERSION,
          description: INFO_DESCRIPTION
        }
      end
      private_class_method :info

      # Unmemoized; the served bytes come from {.json}.
      def self.build_json(**)
        JSON.generate(build(**))
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

      # The registered verbs: one path and its components per verb.
      module Verbs
        def self.add_entries(schemas, paths)
          entries.each do |kind, descriptor|
            name  = descriptor[:name].to_s
            input = descriptor[:input_schema]
            schemas.merge!(Refs.components_for(descriptor[:output_schema], "#{name}.response"))
            schemas.merge!(Refs.components_for(input, "#{name}.request")) if request_component?(kind, input)
            paths["/#{name}"] = { http_method(kind) => operation(kind, descriptor) }
          end
        end

        # Sorted by name across both registries; one name is one kind.
        def self.entries
          (Queries.catalog.map { |d| [:query, d] } + Actions.catalog.map { |d| [:action, d] })
            .sort_by { |(_kind, descriptor)| descriptor[:name].to_s }
        end

        def self.http_method(kind) = kind == :query ? :get : :post

        def self.operation(kind, descriptor)
          name = descriptor[:name].to_s
          op = { operationId: name, tags: [kind == :query ? 'queries' : 'actions'] }
          op[:description] = descriptor[:description] unless descriptor[:description].nil?
          if kind == :query
            op[:parameters] = query_parameters(name, descriptor[:input_schema])
          else
            op[:requestBody] = request_body(name, descriptor[:input_schema])
          end
          op[:responses] = responses(kind, descriptor)
          op
        end

        def self.query_parameters(name, input_schema)
          properties = ArgumentDecoder.fetch(input_schema, :properties) || {}
          required   = Array(ArgumentDecoder.fetch(input_schema, :required)).map(&:to_s)
          base       = "#{name}.request"
          map        = Refs.ref_map(input_schema, base)
          declared = properties.map do |property, schema|
            query_parameter(property.to_s, schema, required, Refs.rewrite_refs(schema, map, base))
          end
          declared + reserved_parameter_refs(properties.keys.map(&:to_s))
        end

        def self.query_parameter(name, schema, required_names, rewritten)
          {
            name: name,
            in: 'query',
            required: required_names.include?(name),
            # Explicit: some tools ignore the OAS defaults.
            style: style_for(schema),
            explode: true,
            schema: rewritten
          }
        end

        # `limit`/`cursor` are always accepted, so add each one the verb did not declare.
        def self.reserved_parameter_refs(declared)
          ArgumentDecoder::RESERVED.keys.reject { |reserved| declared.include?(reserved) }
                                   .map { |reserved| { '$ref': "#/components/parameters/#{reserved}" } }
        end

        # OAS 3.1.1 §4.8.12.3: `deepObject` is for objects only.
        def self.style_for(schema)
          ArgumentDecoder.declared_type(schema) == 'object' ? 'deepObject' : 'form'
        end

        # Required only when the schema requires a property; an absent body reads as `{}`.
        def self.request_body(name, input_schema)
          {
            required: !Array(ArgumentDecoder.fetch(input_schema, :required)).empty?,
            content: Refs.json_content("#{name}.request")
          }
        end

        def self.responses(kind, descriptor)
          ok = {
            description: ArgumentDecoder.fetch(descriptor[:output_schema], :description) || "The verb's result.",
            content: Refs.json_content("#{descriptor[:name]}.response")
          }
          ok[:headers] = Parameters::PAGINATION_HEADERS.keys.index_with { |h| { '$ref': "#/components/headers/#{h}" } } if kind == :query
          { '200' => ok }.merge(Wire.problem_refs)
        end

        # A query's input is a component only when a parameter points into it.
        def self.request_component?(kind, input_schema)
          kind == :action || Refs.contains_ref?(input_schema)
        end
      end

      # `$defs` hoisting and `$ref` rewriting between a descriptor and `components/schemas`.
      module Refs
        module_function

        def json_content(component)
          { 'application/json' => { schema: { '$ref': "#/components/schemas/#{component}" } } }
        end

        # Hoists the schema's root `$defs` into `components/schemas` as
        # `<verb>.<slot>.<name>` and rewrites the `$ref`s to match.
        def components_for(schema, base)
          defs = ArgumentDecoder.fetch(schema, :$defs)
          map  = ref_map(schema, base)
          body = schema.is_a?(::Hash) ? schema.reject { |key, _| key.to_s == '$defs' } : schema
          out  = { base => rewrite_refs(body, map, base) }
          return out unless defs.is_a?(::Hash)

          defs.each { |name, definition| out["#{base}.#{name}"] = rewrite_refs(definition, map, "#{base}.#{name}") }
          out
        end

        def ref_map(schema, base)
          defs = ArgumentDecoder.fetch(schema, :$defs)
          return {} unless defs.is_a?(::Hash)

          defs.keys.to_h { |name| ["#/$defs/#{name}", "#/components/schemas/#{base}.#{name}"] }
        end

        # Document-relative refs only; external ones are left alone.
        def rewrite_refs(node, map, base)
          case node
          when ::Hash then node.to_h { |key, value| [key, rewrite_member(key, value, map, base)] }
          when ::Array then node.map { |element| rewrite_refs(element, map, base) }
          else node
          end
        end

        def rewrite_member(key, value, map, base)
          return rewrite_refs(value, map, base) unless key.to_s == '$ref' && value.is_a?(::String) && value.start_with?('#')

          rewrite_ref(value, map, "#/components/schemas/#{base}")
        end

        def rewrite_ref(ref, map, prefix)
          return prefix if ref == '#'

          hit = map.keys.find { |pointer| ref == pointer || ref.start_with?("#{pointer}/") }
          return "#{map.fetch(hit)}#{ref.delete_prefix(hit)}" if hit

          "#{prefix}#{ref.delete_prefix('#')}"
        end

        def contains_ref?(node)
          case node
          when ::Hash  then node.any? { |key, value| key.to_s == '$ref' || contains_ref?(value) }
          when ::Array then node.any? { |element| contains_ref?(element) }
          else false
          end
        end
      end

      # The protocol's own endpoints (§8.3, §11.3), declared rather than derived,
      # and the problem responses every operation shares.
      module Wire
        SCHEMA_DESCRIPTION = "This origin's catalog: every query and action it publishes, " \
                             'with their descriptions and schemas. THE canonical surface ' \
                             'description — this OpenAPI document is derived from it. ' \
                             'PUBLIC: no credential is required. The MODULE set this origin ' \
                             'serves is `capabilities` in /.well-known/kiosk.json.'

        PAY_DESCRIPTION = "Pay an operator's checkout: submit the closed AP2 checkout and " \
                          'payment mandates. Answers 402 `payment_setup_required` when the ' \
                          'identity has no card on file and 402 `payment_failed` when the ' \
                          "charge did not settle — branch on the problem document's `code`."

        module_function

        # The `Problem` schema, plus `/schema` and `/pay` when their modules are served.
        def surface(modules)
          schemas = { 'Problem' => Components::PROBLEM }
          paths   = {}
          if modules.include?('schema')
            schemas.merge!(Components::SCHEMA)
            paths['/schema'] = { get: schema_operation }
          end
          return [schemas, paths] unless modules.include?('pay')

          [schemas.merge(Components::PAY), paths.merge('/pay' => { post: pay_operation })]
        end

        def components(schemas)
          {
            securitySchemes: { dpopAuth: Parameters::DPOP_SCHEME },
            parameters: Parameters::RESERVED_PARAMETERS,
            headers: Parameters::PAGINATION_HEADERS,
            responses: problem_responses,
            schemas: schemas
          }
        end

        def schema_operation
          {
            operationId: 'schema',
            tags: ['wire'],
            description: SCHEMA_DESCRIPTION,
            # Public: opts out of the global `dpopAuth`.
            security: [],
            responses: ok_responses('The catalog.', 'schema.response')
          }
        end

        def pay_operation
          {
            operationId: 'pay',
            tags: ['wire'],
            description: PAY_DESCRIPTION,
            requestBody: { required: true, content: Refs.json_content('pay.request') },
            responses: ok_responses('The settlement receipt.', 'pay.response')
          }
        end

        def ok_responses(description, component)
          { '200' => { description: description, content: Refs.json_content(component) } }.merge(problem_refs)
        end

        def problem_refs
          problem_statuses.to_h { |status| [status.to_s, { '$ref': "#/components/responses/problem#{status}" }] }
        end

        def problem_statuses
          Errors::CODES.reject { |code, _| code == METHOD_NOT_ALLOWED }.values.uniq.sort
        end

        def problem_responses
          problem_statuses.to_h { |status| ["problem#{status}", problem_response(status)] }
        end

        def problem_response(status)
          codes = Errors::CODES.select { |_, value| value == status }.keys
          response = {
            description: "#{codes.join(' · ')} — see the problem document's `code`.",
            content: { Errors::PROBLEM_CONTENT_TYPE => { schema: { '$ref': '#/components/schemas/Problem' } } }
          }
          status == 402 ? response.merge(headers: Parameters::CHALLENGE_HEADERS) : response
        end
      end

      # The declared schemas and parameters of the protocol's own endpoints.
      module Components
        PROBLEM = {
          type: 'object',
          title: 'Problem document (RFC 9457)',
          description: 'Every error on this wire. Branch on `code`.',
          properties: {
            type: {
              type: 'string', format: 'uri',
              description: "`#{Errors::PROBLEM_TYPE_BASE}<code>` — an IDENTIFIER for the " \
                           'problem type, not a document to fetch. Never branch on it.'
            },
            title: { type: 'string',
                     description: 'A constant summary of the problem TYPE, not of this incident.' },
            status: { type: 'integer', description: 'The HTTP status, repeated.' },
            detail: { type: 'string',  description: 'What went wrong THIS time.' },
            code: { type: 'string', enum: Errors::CODES.keys,
                    description: 'THE BRANCH POINT: the closed Kiosk error vocabulary.' },
            hint: { type: 'string',
                    description: 'How to recover, when the error knows. Present on the errors ' \
                                 'a caller can do something about.' },
            challenges: { type: 'array',
                          description: 'On a `pow_required` 402: the proof-of-work challenges to ' \
                                       'solve and echo back in the `Kiosk-PoW` request header.' }
          },
          required: %w[type title status code]
        }.freeze

        DESCRIPTOR = {
          type: 'object', title: 'One verb descriptor',
          properties: {
            name: { type: 'string', pattern: OpenApi::NAME_PATTERN },
            description: { type: %w[string null],
                           description: "The verb's SEMANTICS, in prose. Authoritative." },
            reach: { type: 'string', enum: HandlerMixin::REACHES.map(&:to_s),
                     description: 'Whose rows this verb may touch (spec §7.2). ' \
                                  '`principal` is the default and the norm; the ' \
                                  'other three are declared departures.' },
            input_schema: { type: 'object',
                            description: "JSON Schema (draft 2020-12) for this verb's inputs. " \
                                         'The authoritative input contract.' },
            output_schema: { type: 'object',
                             description: 'JSON Schema (draft 2020-12) for what this verb returns.' },
            example_params: { description: 'Example inputs an assistant can copy as a ' \
                                           'starting call. It ILLUSTRATES `input_schema` ' \
                                           'and is not the contract: where the two ' \
                                           'disagree, the schema is right.' },
            example_row: { description: 'Example of one result element — a ' \
                                        'representative row for a query, or the return ' \
                                        'value for an action. It ILLUSTRATES ' \
                                        '`output_schema` and is not the contract.' }
          },
          required: %w[name description reach input_schema output_schema],
          additionalProperties: false
        }.freeze

        TOPIC = {
          type: 'object', title: 'One event topic',
          properties: {
            name: DESCRIPTOR[:properties][:name],
            description: { type: %w[string null], description: "The topic's SEMANTICS, in prose. Authoritative." },
            reach: { type: 'string', enum: HandlerMixin::REACHES.map(&:to_s), description: 'Whose events a subscriber may read (spec §7.2).' },
            payload_schema: { description: "JSON Schema (draft 2020-12) for the event's `data`." },
            examples: { type: 'array', description: 'Example `data` objects. They ILLUSTRATE `payload_schema` and are not the contract.' }
          },
          required: %w[name description reach payload_schema],
          additionalProperties: false
        }.freeze

        SCHEMA = {
          'schema.response' => {
            type: 'object', title: 'The `schema` catalog',
            properties: {
              queries: { type: 'array', items: { '$ref': '#/components/schemas/schema.descriptor' } },
              actions: { type: 'array', items: { '$ref': '#/components/schemas/schema.descriptor' } },
              events: { type: 'array', items: { '$ref': '#/components/schemas/schema.topic' } }
            },
            required: %w[queries actions events],
            additionalProperties: false
          },
          'schema.descriptor' => DESCRIPTOR,
          'schema.topic' => TOPIC
        }.freeze

        PAY = {
          'pay.request' => {
            type: 'object', title: 'The two closed AP2 mandates',
            properties: %w[checkout payment].to_h do |what|
              [:"#{what}_mandate", { type: 'string', description: "Compact SD-JWT: the closed AP2 #{what} mandate." }]
            end,
            required: %w[checkout_mandate payment_mandate],
            additionalProperties: false
          },
          'pay.response' => {
            type: 'object', title: 'Settlement and its AP2 receipts',
            properties: {
              settlement_id: { type: 'string', description: "This origin's settlement row id." },
              psp_reference: { type: 'string', description: "The processor's own reference." },
              settled_amount_cents: { type: 'integer' },
              currency: { type: 'string' },
              **%w[checkout payment].to_h { [:"#{it}_receipt", { type: 'string', description: "The AP2 #{it} receipt: a JWT this origin signs EdDSA." }] }
            },
            required: %w[settlement_id psp_reference settled_amount_cents currency checkout_receipt payment_receipt],
            additionalProperties: false
          }
        }.freeze
      end

      # The reserved query parameters, the shared response headers and the DPoP scheme.
      module Parameters
        DPOP_SCHEME = {
          type: 'http',
          scheme: 'DPoP',
          description: 'An access token from the token endpoint ' \
                       '(`POST <endpoint>/oauth/token`), ' \
                       'verifiable against `<endpoint>/.well-known/jwks.json` and bound to the ' \
                       'registered key: send it as `Authorization: DPoP <token>` with a `DPoP` ' \
                       'proof header that the key signs (RFC 9449).'
        }.freeze

        # §8.4. OAS 3.1 §4.8.21.1: a Header Object carries no `name` or `in`.
        PAGINATION_HEADERS = {
          'Link' => {
            description: 'RFC 8288 (Web Linking). Carries `rel="next"` when this answer was ' \
                         'TRUNCATED: fetch that target URI verbatim for the following page. ' \
                         'ABSENT means this is the last (or only) page. The target repeats this ' \
                         'request with the reserved `cursor` parameter set to an OPAQUE token — ' \
                         'follow it, do not parse it.',
            required: false,
            schema: { type: 'string' }
          },
          'X-Total-Count' => {
            description: 'How many rows MATCH the query across all pages — not how many this ' \
                         'response carries. A DE-FACTO CONVENTION, not a standard: no RFC ' \
                         'defines it. Omitted when the operator does not know the total, so ' \
                         'treat it as advisory and never as a loop bound.',
            required: false,
            schema: { type: 'integer', minimum: 0 }
          }
        }.freeze

        # The two 402 gates differ by challenge header (RFC 7235).
        CHALLENGE_HEADERS = {
          'WWW-Authenticate' => {
            description: '`Kiosk-PoW realm="<issuer>"` for a proof-of-work toll, ' \
                         '`Kiosk-Payment-Setup realm="<issuer>"` for payment setup.',
            schema: { type: 'string' }
          }
        }.freeze

        RESERVED_PARAMETERS = {
          'limit' => {
            name: 'limit',
            in: 'query',
            required: false,
            style: 'form',
            explode: true,
            description: 'Maximum rows in one page. The operator MAY clamp it. ' \
                         'Reserved: always accepted. A query MAY declare it to bound the page size.',
            schema: { type: ArgumentDecoder::RESERVED.fetch('limit'), minimum: 1 }
          },
          'cursor' => {
            name: 'cursor',
            in: 'query',
            required: false,
            style: 'form',
            explode: true,
            description: 'The OPAQUE `next` token from the previous page, echoed back ' \
                         'verbatim. Never parse or construct one. ' \
                         'Reserved: always accepted, never declared.',
            schema: { type: ArgumentDecoder::RESERVED.fetch('cursor') }
          }
        }.freeze
      end
    end
  end
end
