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
    # THE DERIVED OPENAPI RENDERER (T-068 slice 4, decision T-071 = C,
    # ADR-0024).
    #
    # A SECOND RENDERER over the SAME model `GET <endpoint>/schema` renders:
    # {Queries.catalog} and {Actions.catalog}, read exactly as
    # {SchemaDocument} reads them. Nothing here holds a declaration of
    # its own, and nothing here may be edited to say something the descriptors
    # do not — that is the whole property the decision bought, and it is the
    # same one {WellKnown} already proves across six discovery surfaces.
    #
    # ── What this is FOR, and what it is not ─────────────────────────────
    #
    # `/kiosk/schema` stays CANONICAL. It is what `skill.md` teaches, it is
    # what an AI assistant reads, and it is the only catalog the spec makes
    # normative. `/kiosk/openapi.json` is for TOOLING — a porter pointing a
    # code generator, a mock server or a request validator at a Kiosk origin —
    # and it is named NOWHERE in the skill, so no assistant pays cold-start
    # context for it. That property is the reason the decision went to C
    # rather than to "OpenAPI replaces the catalog"; do not undermine it by
    # teaching this document anywhere an assistant reads.
    #
    # ADR-0021 («Explicitly NOT OpenAPI») is NARROWED by this, not reversed:
    # OpenAPI is an ADDITIONAL DESCRIPTION surface. The prose `description`
    # remains the authoritative SEMANTICS and `input_schema` the authoritative
    # INPUT CONTRACT — both travel into this document verbatim rather than
    # being restated in it.
    #
    # ── PROVISIONAL, by Phil's own revisit clause ────────────────────────
    #
    # «Если не понадобится, уберём». So: nothing else may come to depend on
    # this document. It is a pure derivation with no independent source of
    # truth, and removing it stays ONE FILE plus ONE `items <<` line in
    # {WellKnown.api_catalog} plus the route and the controller. Do not let a
    # demo, the e2e harness, the skill or the normative spec require it.
    #
    # ── The four things the T-086 research says this must get right ──────
    #
    #   1. `style` and `explode` are written EXPLICITLY on every parameter.
    #      Stoplight Prism 5.16.0 ignores the spec's defaults (`el.explode ||
    #      false`), and `deepObject` + `explode: false` is UNDEFINED per OAS
    #      3.1.2 — so a document that omits them is a document that disagrees
    #      with us in someone else's tool.
    #   2. Parameter NAMES are the honest declared names — never `a[]`. The
    #      bracket name is legal OpenAPI and every generator measured
    #      serialises it, but ten of the twelve validators surveyed reject or
    #      break on it, and a renderer that renamed `amenity` to `amenity[]`
    #      would have stopped being a derivation of the descriptor. The
    #      BRACKETS ARE A WIRE SPELLING, not a name: `style: form, explode:
    #      true` emits `?a=1&a=2`, which {ArgumentDecoder#fold_declared_arrays}
    #      reads as an array precisely because the schema declares one, and
    #      the `a%5B%5D=` form the skill teaches parses to the same arguments.
    #      One taught form, one tolerated form, one declared name.
    #   3. An OBJECT parameter is `style: deepObject, explode: true` — the one
    #      query style OpenAPI defines that Rails already speaks — and it is
    #      ONE LEVEL WITH SCALAR LEAVES (T-087). The decoder refuses anything
    #      richer, so no such shape can reach a descriptor and be published.
    #   5. THE TWO PAGINATION FACTS ARE RESPONSE HEADERS, and OpenAPI declares
    #      a response header in `responses.<code>.headers` — NOT as a property
    #      of the body schema. Getting that wrong would publish `Link` and
    #      `X-Total-Count` as fields of a row array, which is not merely
    #      useless to a generator: it is a false statement about the body, and
    #      this document's whole warrant is that it says only what the
    #      descriptors say. The two live in `components.headers` and are
    #      `$ref`d from every QUERY's `200`; actions never paginate (spec
    #      §8.4), so their operations do not carry them.
    #   4. `limit` and `cursor` are INJECTED into every query operation. They
    #      are reserved names the wire always accepts and a verb never has to
    #      declare (§8.1 item 6), so they appear in no `input_schema` — and a
    #      strict validator in front of a porter's server answers `400 Unknown
    #      query parameter 'limit'` to the very pagination §8.4 invites unless
    #      the derived document declares them. Measured on
    #      express-openapi-validator 5.6.2. A verb that DOES declare one wins:
    #      its own declaration is the more specific statement and the
    #      injection stands down, because two parameters with the same
    #      `name`+`in` is an invalid document.
    #
    # ── What the document describes ──────────────────────────────────────
    #
    # The whole wire: `GET <endpoint>/<query-name>`,
    # `POST <endpoint>/<action-name>`, and the two RESERVED endpoints
    # `GET <endpoint>/schema` and `POST <endpoint>/pay`, which joined at the
    # 0.4 cutover in the same wave that moved them onto the payload-verbatim
    # shape (T-074 = A). Before that they still answered the 0.3 envelope, and
    # describing them would have published an envelope that was being deleted.
    #
    # THE TWO RESERVED OPERATIONS ARE THE ONE PLACE THIS RENDERER SPEAKS FOR
    # ITSELF, and it is worth being precise about why that is not the drift
    # the file exists to prevent. `schema` and `pay` are not the OPERATOR's
    # verbs: no `Kiosk::Handler` declaration produces them,
    # nobody can register them (they are in
    # {HandlerMixin::RESERVED_NAMES}), and their contract is fixed by the
    # SPECIFICATION — §8.3 for the catalog, §11.3 for the settlement — not by
    # anything on this origin. So describing them here restates the protocol,
    # exactly as {INFO_DESCRIPTION} already does, and the invariant that
    # matters is untouched: nothing here may say anything about an OPERATOR
    # verb that the verb's own three fields do not.
    #
    # Both are gated on `config.capabilities`, which is computed from the live
    # registry and drops `pay` on an origin with no payment provider — so the
    # document describes what this origin ANSWERS, never what the protocol
    # allows in general.
    module OpenApi
      # The OAS version the document declares. 3.1.x is the line whose Schema
      # Objects ARE JSON Schema 2020-12, which is what makes embedding a
      # descriptor's `input_schema`/`output_schema` VERBATIM possible at all —
      # under 3.0 they would have to be translated into its schema dialect,
      # and a translation is not a derivation. `3.1.0` rather than `3.1.2`
      # because it is the patch the surveyed tooling was measured against and
      # the deltas since are editorial.
      OPENAPI_VERSION = "3.1.0"

      # Written EXPLICITLY even though 3.1 defaults to it: the descriptors are
      # draft 2020-12 (§8.3) and a document that leaves its dialect implicit
      # invites a consumer to guess.
      JSON_SCHEMA_DIALECT = "https://json-schema.org/draft/2020-12/schema"

      # The OAI-registered media type for an OpenAPI document in JSON. The
      # `+json` structured suffix means a generic JSON client handles it
      # unchanged, while a tool that cares can tell an API description from
      # any other JSON body.
      CONTENT_TYPE = "application/vnd.oai.openapi+json;version=3.1"

      # `405 method_not_allowed` is in the vocabulary (slice 2) but is NOT a
      # response of any operation HERE: it is what the OTHER method at a
      # verb's path answers, and that method is not a declared operation.
      # Declaring it as an operation that always fails would put a broken
      # client method in every generated SDK. The rule is stated once in
      # `info.description` instead.
      METHOD_NOT_ALLOWED = "method_not_allowed"

      # Prose the RENDERER owns — about the protocol, never about a verb. A
      # verb's meaning comes from its own `description` and travels verbatim.
      INFO_DESCRIPTION = <<~TEXT.strip
        A DERIVED description of this origin's Kiosk verbs, generated from the
        same registry `GET <endpoint>/schema` renders. `schema` is the
        canonical catalog and this document is a convenience for tooling; where
        the two could ever disagree, `schema` is right.

        Every verb is its own endpoint: a query is a GET whose arguments are in
        the query string, an action is a POST whose arguments are a JSON body.
        There is no third channel. Calling a verb with the other method answers
        `405` with an `Allow` header naming the one it accepts — that is a
        different answer from `404`, because the resource exists.

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

      # Build the document as a Hash, ready to JSON-serialize.
      #
      # @param base_url [String] the origin the request arrived at
      #   (`request.base_url`), so a document served from a staging host names
      #   the staging host
      # @param config [Kiosk::Configuration]
      # @return [Hash]
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

      # JSON-encoded form of {.build}. Unmemoized on purpose — it is the seam a
      # spec or a script uses to render one document for one base URL without
      # touching process state. The SERVED bytes come from {.json}.
      def self.build_json(**kwargs)
        JSON.generate(build(**kwargs))
      end

      # ── WHAT THE ENDPOINT SERVES, AND ITS VALIDATOR (K-804) ─────────────
      #
      # `GET <endpoint>/openapi.json` is public and cacheable now, so it owes a
      # caller a strong `ETag` and a 304 — and neither is affordable if the
      # document is re-derived on every request just to be hashed. Same memo
      # {SchemaDocument} keeps, with ONE difference that is worth stating
      # because it is the reason this document is not derived at boot beside
      # the catalog: THIS ONE DEPENDS ON `base_url`. `servers[0].url` names the
      # origin the request arrived at, so a staging host describes itself and
      # not production — and no boot hook knows what host a request will use.
      # First request per origin pays; every later one is a string write.
      #
      # THE MEMO KEY IS `[base_url, SchemaDocument.digest]`, and that is a
      # claim worth checking rather than trusting: every input of {.build}
      # other than `base_url` — the two registries, `capabilities`,
      # `mount_path`, `owner`, `issuer`, the protocol version, this gem's
      # version — is an input of {SchemaDocument.digest_inputs}. So the
      # catalog's digest is the ORIGIN'S DOCUMENT VERSION, not the catalog's
      # alone, which is also why it is what the api-catalog hangs on BOTH
      # `?v=` links ({WellKnown.api_catalog}).
      #
      # The ETAG IS THIS DOCUMENT'S OWN BYTES, not that shared version: an
      # entity tag identifies the representation at ONE url, and two origins
      # (or a staging host and production) render different bytes under the
      # same version. Hashing what we are about to write is exact and costs
      # nothing extra — we have just serialized it.
      DIGEST_LENGTH = 32

      class << self
        # The serialized document for this origin.
        def json(base_url:, config: Kiosk.configuration)
          derive(base_url: base_url, config: config).fetch(:json)
        end

        # The strong HTTP entity tag: SHA-256 of {json}, truncated and quoted.
        def etag(base_url:, config: Kiosk.configuration)
          %("#{derive(base_url: base_url, config: config).fetch(:digest)}")
        end

        # Drop the memo. {Engine} calls this from `to_prepare`, beside
        # {SchemaDocument.reset!}, so a development reload cannot serve a
        # document describing verbs that have just been renamed.
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

      # ── the model ───────────────────────────────────────────────────────

      # THE one model, read the one way. `[[:query, descriptor], …]` sorted by
      # wire name across both registries — which is a total order, because one
      # name is one kind ({HandlerRegistrations.refuse_cross_kind_collisions!}).
      def self.entries
        (Queries.catalog.map { |d| [:query, d] } + Actions.catalog.map { |d| [:action, d] })
          .sort_by { |(_kind, descriptor)| descriptor[:name].to_s }
      end
      private_class_method :entries

      def self.http_method(kind) = kind == :query ? :get : :post
      private_class_method :http_method

      # ── one operation ───────────────────────────────────────────────────

      def self.operation(kind, descriptor)
        name = descriptor[:name].to_s
        op = {
          operationId: name,
          tags:        [kind == :query ? "queries" : "actions"],
        }
        # A descriptor's `description` is the AUTHORITATIVE SEMANTICS
        # (ADR-0021/0023) and travels VERBATIM. It is `String|nil` on the wire;
        # an absent one is omitted rather than emitted as an empty string.
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

      # A query's arguments, one OpenAPI parameter per declared property, plus
      # the two reserved names the verb did not declare itself.
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
            # EXPLICIT, both of them, on every parameter. See the module note.
            style:    style_for(schema),
            explode:  true,
            schema:   rewrite_refs(schema, map, base),
          }
        end

        # The injection (research finding 4). Skipped for a name the verb
        # declared itself — that declaration is the more specific statement,
        # the decoder already honours it, and two parameters sharing a
        # `name`+`in` would be an invalid document.
        ArgumentDecoder::RESERVED.each_key do |reserved|
          next if declared.include?(reserved)

          parameters << { "$ref": "#/components/parameters/#{reserved}" }
        end

        parameters
      end
      private_class_method :query_parameters

      # `deepObject` is for objects and ONLY for objects (OAS 3.1.1 §4.8.12.3:
      # its `type` column is `object`, its `array` cell is *n/a*). Everything
      # else — scalars and arrays of scalars — is `form`. The type is read with
      # the DECODER's own reader, so a nullable union (`["string","null"]`)
      # answers the same here as it does when the wire coerces it.
      def self.style_for(schema)
        ArgumentDecoder.declared_type(schema) == "object" ? "deepObject" : "form"
      end
      private_class_method :style_for

      # An action's body IS its `input_schema`, referenced rather than inlined
      # so the one declaration has one home in the document.
      #
      # `required` is DERIVED: a body is required exactly when the schema
      # requires at least one property. A verb declaring the closed empty
      # object takes nothing, and the wire reads an absent body as `{}` — so
      # claiming the body is mandatory there would be a claim the server does
      # not enforce.
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
          # The Response Object's `description` is REQUIRED by OAS. Use the
          # operator's own words for the answer when the declaration carries
          # them; fall back to a neutral sentence, never to invented prose.
          description: ArgumentDecoder.fetch(output, :description) || "The verb's result.",
          content:     {
            "application/json" => { schema: { "$ref": "#/components/schemas/#{name}.response" } },
          },
        }
        # The pagination pair, on QUERIES ONLY (research point 5). Declared as
        # RESPONSE HEADERS, which is where OpenAPI puts one; a query that never
        # paginates simply never sends them, and both are `required: false`.
        ok[:headers] = PAGINATION_HEADERS.keys.to_h { |h| [h, { "$ref": "#/components/headers/#{h}" }] } if kind == :query

        { "200" => ok }.merge(problem_refs)
      end
      private_class_method :responses

      # ── embedded schemas ────────────────────────────────────────────────

      # A `$ref` inside a descriptor's schema is written against THAT schema's
      # own root — hoteling's `search_hotels` says `#/$defs/hotel`. Embedded in
      # an OpenAPI document, `#` is the DOCUMENT root, so the pointer would
      # dangle.
      #
      # THE ROOT `$defs` IS HOISTED into `components/schemas` — one component
      # per definition, `<verb>.<slot>.<name>` — and the pointers are rewritten
      # to name it. The obvious cheaper fix is to leave `$defs` where the
      # operator wrote it and just re-base the pointer into the component
      # (`#/components/schemas/search_hotels.response/$defs/hotel`), which is a
      # legal JSON Pointer and which json_schemer resolves — but MEASURED,
      # `openapi_parser` 2.3.1 (the parser `committee` 5.6.3 is built on)
      # answers `MissingReferenceError` to it, because it resolves only
      # pointers that land on a known component container. Hoisting costs ten
      # lines and lands every pointer on a plain top-level component, which
      # nothing surveyed stumbles on. Definitions keep their names; only their
      # address changes.
      #
      # @return [Hash] `{"<verb>.<slot>" => schema, "<verb>.<slot>.<def>" => …}`
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

      # `{"#/$defs/hotel" => "#/components/schemas/search_hotels.response.hotel"}`
      # — the new address of every hoisted definition, computed once per schema
      # so a parameter inlined out of it points at the same place its component
      # does.
      def self.ref_map(schema, base)
        defs = ArgumentDecoder.fetch(schema, :"$defs")
        return {} unless defs.is_a?(::Hash)

        defs.keys.each_with_object({}) do |name, out|
          out["#/$defs/#{name}"] = "#/components/schemas/#{base}.#{name}"
        end
      end
      private_class_method :ref_map

      # Deep-copies +node+, rewriting every document-relative `$ref`:
      # a pointer at (or into) a hoisted definition follows it to its new
      # component; anything else document-relative is re-based onto the
      # component named by +base+, which is where the enclosing schema now
      # lives. External refs (`https://…`, `other.json#/x`) are left alone —
      # they were never relative to the descriptor's root.
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

      # A query publishes its `input_schema` as a component only when
      # something in the document points INTO it — i.e. when one of its
      # parameter schemas carries a re-based `$ref`. An action always does
      # (the request body is that reference). Publishing it unconditionally
      # would leave 27 components nothing links to, which every OpenAPI linter
      # reports.
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

      # ── the two RESERVED endpoints (spec §8.3 and §11.3) ────────────────
      #
      # See the module note for why these are declared here rather than
      # derived: they are the PROTOCOL's verbs, not the operator's, and no
      # declaration on this origin describes them.

      def self.schema_operation
        {
          operationId: "schema",
          tags:        ["wire"],
          description: "This origin's catalog: every query and action it publishes, " \
                       "with their descriptions and schemas. THE canonical surface " \
                       "description — this OpenAPI document is derived from it. " \
                       "PUBLIC: no credential is required. The MODULE set this origin " \
                       "serves is `capabilities` in /.well-known/kiosk.json.",
          # The document declares `bearerAuth` globally; this ONE operation
          # opts out. An empty `security` array is OpenAPI's way of saying
          # "no credential required" (T-094), and getting it wrong here would
          # make a generated client send a token this endpoint never reads —
          # or, worse, refuse to call it without one.
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

      # The descriptor shape §8.3 fixes. `params` is the RETIRED slot and is
      # published as null; `input_schema`/`output_schema` are REQUIRED and are
      # arbitrary draft-2020-12 documents, so they are described as objects
      # rather than constrained — a schema for a schema would be a second
      # statement of what draft 2020-12 already says.
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
              params:         { type: "null", description: "Retired (spec §8.3); always null." },
              input_schema:   { type: "object",
                                description: "JSON Schema (draft 2020-12) for this verb's inputs. " \
                                             "The authoritative input contract." },
              output_schema:  { type: "object",
                                description: "JSON Schema (draft 2020-12) for what this verb returns." },
              example_params: { description: "OPTIONAL example inputs." },
              example_row:    { description: "OPTIONAL example of one result element." },
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

      # Request: §11's three mandates. Response: the four fields
      # {Executor#verb_pay} renders, and only those.
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

      # The problem responses every operation carries, as `$ref`s.
      def self.problem_refs
        problem_statuses.each_with_object({}) do |status, out|
          out[status.to_s] = { "$ref": "#/components/responses/problem#{status}" }
        end
      end
      private_class_method :problem_refs

      # ── components that are the same for every origin ───────────────────

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

      # The two reserved parameters, declared once and referenced from every
      # query. Types come from the DECODER's own table, so the document cannot
      # say `limit` is a string while the wire coerces it to an integer.
      # THE PAGINATION RESPONSE HEADERS (spec §8.4), as OAS Header Objects.
      # `name` and `in` are deliberately ABSENT: OAS 3.1 §4.8.21.1 says a
      # Header Object is a Parameter Object minus those two, because the map
      # key already names the header. A generator that saw them would reject
      # the document.
      #
      # THE HONESTY THE SPEC INSISTS ON travels with them: `Link` cites RFC
      # 8288 because there IS one; `X-Total-Count` says in its own description
      # that it is a widely-used convention with no standard behind it, and it
      # says what it counts — matching rows, not returned rows — because those
      # two differ on every page but the last.
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

      # Statuses an operation can actually answer with, derived from the closed
      # vocabulary. 405 is excluded — see {METHOD_NOT_ALLOWED}.
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
          # RFC 7235: the two 402 gates are told apart by the challenge header,
          # not by the status. The wire emits it, so the document says so.
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

      # RFC 9457 problem document. The `code` enum IS {Errors::CODES} — the
      # closed vocabulary, published here as the branch point an assistant (and
      # a validator) reads, exactly as the spec's error table publishes it.
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
