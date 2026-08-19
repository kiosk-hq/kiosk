# frozen_string_literal: true

# THE DERIVED OPENAPI RENDERER (T-068 slice 4, T-071 = C, ADR-0024).
#
# Three things are proved here and they are different kinds of claim:
#
#   1. IT IS A DERIVATION. Everything in the document traces to a descriptor
#      in the SAME registry `GET <endpoint>/schema` renders from — so the
#      sharpest examples are the ones that CHANGE a declaration and watch the
#      document follow, because a second source of truth would not.
#   2. IT SAYS WHAT THE T-086 RESEARCH MEASURED IT MUST. `style`/`explode`
#      written explicitly, honest parameter names, `deepObject` for objects
#      only, `limit`/`cursor` injected.
#   3. IT CONFORMS, ACCORDING TO SOMEBODY ELSE'S PARSER. The last block hands
#      the document to `openapi_first` — a third-party OpenAPI 3.1
#      implementation — and validates real Kiosk requests and real Kiosk
#      answers against it. Our own eyes are not evidence.

require "json"
require "rack/mock"

RSpec.describe Kiosk::Server::OpenApi do
  before do
    Kiosk.configure do |c|
      c.issuer = "https://demo.example"
      c.owner  = { name: "Combette" }
    end
  end

  def document = described_class.build(base_url: "https://demo.example")

  # The fleet's one paginating verb, in miniature: a two-branch `oneOf` with
  # a `$defs` the branches `$ref`. It is the only shape in the tree that makes
  # pointer rewriting matter, so it is the fixture for it.
  def declare_paginating_query
    declare_query(
      "search_hotels",
      description:  "Search hotels.",
      input_schema: {
        type: "object", additionalProperties: false,
        properties: {
          neighbourhood: { type: "string", enum: %w[Beşiktaş Kadıköy] },
          min_stars:     { type: "integer", minimum: 1 },
          amenity:       { type: "array", items: { type: "string" } },
          filter:        { type: "object", properties: { city: { type: "string" } } },
          note:          { type: %w[string null] },
        },
        required: [],
      },
      output_schema: {
        "$defs": { hotel: { type: "object", additionalProperties: false,
                            properties: { property_id: { type: "integer" } },
                            required: %w[property_id] } },
        description: "One page of matching hotels.",
        oneOf: [
          { type: "array", items: { "$ref": "#/$defs/hotel" } },
          { type: "object", additionalProperties: false,
            properties: { rows: { type: "array", items: { "$ref": "#/$defs/hotel" } },
                          next: { type: "string" } },
            required: %w[rows next] },
        ],
      },
    )
  end

  describe "it is a DERIVATION of the registry, not a second catalog" do
    it "has one path per registered verb, and nothing else" do
      declare_query("salons")
      declare_action("book_appointment")

      expect(document[:paths].keys).to eq(["/book_appointment", "/salons"])
    end

    it "loses a path when the verb leaves the registry" do
      declare_query("salons")
      expect(document[:paths]).to have_key("/salons")

      Kiosk::Server::Queries.unregister("salons")
      expect(document[:paths]).to be_empty
    end

    it "carries the descriptor's prose description VERBATIM — it is the semantics (ADR-0021)" do
      declare_query("salons", description: "Browse the salons this provider takes bookings for.")

      expect(document.dig(:paths, "/salons", :get, :description))
        .to eq("Browse the salons this provider takes bookings for.")
    end

    it "omits `description` rather than inventing one when the descriptor has none" do
      declare_query("salons", description: nil, input_schema: { type: "object" })

      expect(document.dig(:paths, "/salons", :get)).not_to have_key(:description)
    end

    it "titles the document with the SAME name agents.json calls the site" do
      declare_query("salons")

      expect(document.dig(:info, :title))
        .to eq("#{Kiosk::Server::WellKnown.site_name(Kiosk.configuration)} — Kiosk")
    end

    it "names the origin the request arrived at, so a staging host describes staging" do
      declare_query("salons")

      expect(described_class.build(base_url: "https://staging.example/")[:servers])
        .to eq([{ url: "https://staging.example/kiosk", description: "This origin's Kiosk endpoint." }])
    end
  end

  describe "the method carries the read/write semantics" do
    it "puts a query at GET and an action at POST" do
      declare_query("salons")
      declare_action("book_appointment")

      expect(document.dig(:paths, "/salons").keys).to eq([:get])
      expect(document.dig(:paths, "/book_appointment").keys).to eq([:post])
    end

    it "describes ONLY the per-verb wire — `schema` and `pay` answer the 0.3 envelope until the cutover" do
      declare_query("salons")

      expect(document[:paths].keys).not_to include("/schema", "/pay")
    end
  end

  describe "parameters — what the T-086 research measured this must say" do
    before { declare_paginating_query }

    def parameter(name)
      document.dig(:paths, "/search_hotels", :get, :parameters)
              .find { |p| p[:name] == name }
    end

    it "writes `style` and `explode` EXPLICITLY on every parameter" do
      # Stoplight Prism 5.16.0 reads `el.explode || false` — it does not apply
      # the spec's defaults — and `deepObject` + `explode: false` is UNDEFINED
      # per OAS 3.1.2. A document that leaves either implicit is a document
      # that disagrees with this wire inside somebody else's tool.
      parameters = document.dig(:paths, "/search_hotels", :get, :parameters)
      inline     = parameters.reject { |p| p.key?(:"$ref") }

      expect(inline).to all(include(:style, :explode))
      expect(inline.map { |p| p[:explode] }.uniq).to eq([true])
      expect(document.dig(:components, :parameters).values)
        .to all(include(style: "form", explode: true))
    end

    it "declares an ARRAY as `form`, under its HONEST name — never `amenity[]`" do
      # The bracket name is legal OpenAPI and every generator surveyed
      # serialises it, but ten of twelve validators reject or break on it —
      # and a renderer that renamed the parameter would have stopped being a
      # derivation of the descriptor. `form`/`explode: true` emits
      # `?amenity=pool&amenity=spa`, which ArgumentDecoder folds into an array
      # BECAUSE the schema declares one; the `amenity%5B%5D=` spelling the
      # skill teaches parses to the same arguments.
      expect(parameter("amenity")).to include(style: "form", explode: true)
      expect(document.dig(:paths, "/search_hotels", :get, :parameters).map { |p| p[:name] })
        .not_to include("amenity[]", "amenity%5B%5D")
    end

    it "declares an OBJECT as `deepObject` — the one query style OpenAPI defines that Rails speaks" do
      expect(parameter("filter")).to include(style: "deepObject", explode: true)
    end

    it "reads the type through the DECODER's own reader, so a nullable union is not an object" do
      expect(parameter("note")).to include(style: "form")
    end

    it "copies the property's schema verbatim, enum and all" do
      expect(parameter("neighbourhood")[:schema])
        .to eq(type: "string", enum: %w[Beşiktaş Kadıköy])
    end

    it "marks `required` explicitly, from the schema's own required list" do
      declare_query("hotel_detail",
                    input_schema: { type: "object",
                                    properties: { property_id: { type: "integer" },
                                                  check_in: { type: "string" } },
                                    required: ["property_id"] })
      params = document.dig(:paths, "/hotel_detail", :get, :parameters)

      expect(params.find { |p| p[:name] == "property_id" }[:required]).to be(true)
      expect(params.find { |p| p[:name] == "check_in" }[:required]).to be(false)
    end
  end

  describe "the reserved names (T-070 rule 7)" do
    it "INJECTS `limit` and `cursor` into a query that declares neither" do
      # Measured on express-openapi-validator 5.6.2: a strict validator in
      # front of a porter's server answers `400 Unknown query parameter
      # 'limit'` to the very pagination §8.4 invites, unless the derived
      # document declares them. No `input_schema` ever does — §8.1 item 6.
      declare_query("salons", input_schema: { type: "object", additionalProperties: false,
                                              properties: {}, required: [] })

      expect(document.dig(:paths, "/salons", :get, :parameters))
        .to eq([{ "$ref": "#/components/parameters/limit" },
                { "$ref": "#/components/parameters/cursor" }])
    end

    it "takes their types from the DECODER's table, so the document cannot outvote the wire" do
      declare_query("salons")

      expect(document.dig(:components, :parameters, "limit", :schema, :type))
        .to eq(Kiosk::Server::ArgumentDecoder::RESERVED.fetch("limit"))
      expect(document.dig(:components, :parameters, "cursor", :schema, :type))
        .to eq(Kiosk::Server::ArgumentDecoder::RESERVED.fetch("cursor"))
    end

    it "STANDS DOWN for a name the verb declared itself — the declaration is more specific" do
      # And two parameters sharing a name+in would be an invalid document.
      declare_query("search_hotels",
                    input_schema: { type: "object",
                                    properties: { limit: { type: "integer", maximum: 50 } },
                                    required: [] })
      params = document.dig(:paths, "/search_hotels", :get, :parameters)

      expect(params.count { |p| p[:name] == "limit" }).to eq(1)
      expect(params.find { |p| p[:name] == "limit" }[:schema]).to eq(type: "integer", maximum: 50)
      expect(params).to include({ "$ref": "#/components/parameters/cursor" })
    end

    it "does not inject them into an ACTION — an action reads no query string (§8.1)" do
      declare_action("book_appointment")

      expect(document.dig(:paths, "/book_appointment", :post)).not_to have_key(:parameters)
    end
  end

  describe "an action's request body" do
    it "references the `input_schema` component rather than inlining it" do
      declare_action("book_appointment",
                     input_schema: { type: "object", properties: { salon_id: { type: "integer" } },
                                     required: ["salon_id"] })

      expect(document.dig(:paths, "/book_appointment", :post, :requestBody))
        .to eq(required: true,
               content: { "application/json" =>
                 { schema: { "$ref": "#/components/schemas/book_appointment.request" } } })
      expect(document.dig(:components, :schemas, "book_appointment.request"))
        .to eq(type: "object", properties: { salon_id: { type: "integer" } }, required: ["salon_id"])
    end

    it "does not claim the body is required when the verb requires nothing of it" do
      # The wire reads an absent body as `{}`, which satisfies a closed empty
      # object — so "required" there would be a claim the server never enforces.
      declare_action("ping", input_schema: { type: "object", additionalProperties: false,
                                             properties: {}, required: [] })

      expect(document.dig(:paths, "/ping", :post, :requestBody, :required)).to be(false)
    end
  end

  describe "responses" do
    it "publishes the `output_schema` VERBATIM as the 200 body" do
      declare_query("salons",
                    output_schema: { type: "array", description: "The complete public catalogue.",
                                     items: { type: "object", properties: { id: { type: "integer" } } } })

      expect(document.dig(:paths, "/salons", :get, :responses, "200"))
        .to eq(description: "The complete public catalogue.",
               content: { "application/json" =>
                 { schema: { "$ref": "#/components/schemas/salons.response" } } })
      expect(document.dig(:components, :schemas, "salons.response", :items))
        .to eq(type: "object", properties: { id: { type: "integer" } })
    end

    it "publishes an OBJECT-answering query faithfully, §8.2 or not (K-794)" do
      # hoteling's `hotel_detail` answers a bare object where §8.2 says a
      # non-paginating query answers an array. Its `output_schema` declares
      # the TRUTH, and this renderer republishes the truth: hiding the
      # discrepancy behind a normalised array would make the derived document
      # a place where a defect goes to be forgotten.
      declare_query("hotel_detail", output_schema: { type: "object",
                                                     properties: { property_id: { type: "integer" } } })

      expect(document.dig(:components, :schemas, "hotel_detail.response", :type)).to eq("object")
    end

    it "HOISTS a `$defs` into components and follows every pointer to it" do
      # `#/$defs/hotel` is written against the DESCRIPTOR's root; embedded in
      # an OpenAPI document `#` is the document root. Leaving `$defs` in place
      # and pointing into it is legal JSON Pointer that json_schemer resolves
      # — and that openapi_parser 2.3.1 (committee's parser) answers
      # MissingReferenceError to. Hoisting lands the pointer on a plain
      # top-level component instead.
      declare_paginating_query
      schemas = document.dig(:components, :schemas)

      expect(schemas).to have_key("search_hotels.response.hotel")
      expect(schemas["search_hotels.response"]).not_to have_key(:"$defs")
      expect(schemas.dig("search_hotels.response", :oneOf, 0, :items))
        .to eq("$ref": "#/components/schemas/search_hotels.response.hotel")
    end

    it "declares every problem status the closed vocabulary has — and not 405" do
      # 405 is what the OTHER method at this path answers, and that method is
      # not a declared operation; declaring it here would put a
      # permanently-failing method in every generated client.
      declare_query("salons")
      statuses = document.dig(:paths, "/salons", :get, :responses).keys - ["200"]

      expect(statuses).to eq(%w[400 401 402 403 404 409 429 500])
      expect(statuses).not_to include("405")
      expect(document.dig(:components, :responses).keys)
        .to eq(%w[problem400 problem401 problem402 problem403 problem404
                  problem409 problem429 problem500])
    end

    it "serves problems under the RFC 9457 media type, with the CLOSED vocabulary as the code enum" do
      declare_query("salons")

      expect(document.dig(:components, :responses, "problem404", :content).keys)
        .to eq([Kiosk::Server::Errors::PROBLEM_CONTENT_TYPE])
      expect(document.dig(:components, :schemas, "Problem", :properties, :code, :enum))
        .to eq(Kiosk::Server::Errors::CODES.keys)
    end

    it "names the three codes that share 402 and the header that tells them apart" do
      declare_query("salons")
      response = document.dig(:components, :responses, "problem402")

      expect(response[:description])
        .to eq("pow_required · payment_setup_required · payment_failed — see the problem document's `code`.")
      expect(response[:headers]).to have_key("WWW-Authenticate")
    end
  end

  describe "the document's own frame" do
    before { declare_query("salons") }

    it "declares OpenAPI 3.1 and its JSON Schema dialect explicitly" do
      expect(document[:openapi]).to eq("3.1.0")
      expect(document[:jsonSchemaDialect]).to eq("https://json-schema.org/draft/2020-12/schema")
    end

    it "versions itself with the protocol version, not with a version of its own" do
      expect(document.dig(:info, :version)).to eq(Kiosk::Protocol::API_VERSION)
    end

    it "requires the same Bearer identity the wire does" do
      expect(document[:security]).to eq([{ bearerAuth: [] }])
      expect(document.dig(:components, :securitySchemes, :bearerAuth))
        .to include(type: "http", scheme: "bearer")
    end

    it "points at the normative specification as the authority" do
      expect(document.dig(:externalDocs, :url)).to eq("https://kiosk.tech/specification.html")
    end

    it "serialises to JSON" do
      expect(JSON.parse(described_class.build_json(base_url: "https://demo.example")))
        .to be_a(Hash)
    end
  end

  # ── THE CONFORMANCE TEST (T-071 = C asked for exactly one) ────────────────
  #
  # Someone else's OpenAPI 3.1 implementation reads the document and then
  # judges real Kiosk traffic by it. `openapi_first` is a test-only Gemfile
  # entry, so a missing gem is a LOUD failure here rather than a silent skip:
  # a conformance test that can quietly not run is not a gate.
  describe "conformance, judged by a third-party OpenAPI 3.1 implementation" do
    let(:definition) do
      require "openapi_first"
      OpenapiFirst.parse(JSON.parse(described_class.build_json(base_url: "https://demo.example")),
                         path_prefix: Kiosk.configuration.mount_path)
    end

    before { declare_paginating_query }

    def request(method, path, body: nil)
      Rack::Request.new(Rack::MockRequest.env_for(
                          "https://demo.example#{Kiosk.configuration.mount_path}#{path}",
                          method: method,
                          input: body && JSON.generate(body),
                          "CONTENT_TYPE" => body ? "application/json" : nil,
                        ))
    end

    def response(status, payload, content_type: "application/json")
      Rack::Response[status, { "content-type" => content_type }, [JSON.generate(payload)]]
    end

    it "parses as a valid OpenAPI 3.1 document" do
      expect(definition.routes.count).to eq(1)
    end

    it "accepts a scalar query and coerces it to the declared type" do
      validated = definition.validate_request(request("GET", "/search_hotels?min_stars=4"))

      expect(validated).to be_valid
      expect(validated.parsed_params).to eq("min_stars" => 4)
    end

    it "reads `?amenity=pool&amenity=spa` as the array the schema declares" do
      # The form a client generated FROM this document emits, and the form
      # ArgumentDecoder#fold_declared_arrays folds — the two agree.
      validated = definition.validate_request(request("GET", "/search_hotels?amenity=pool&amenity=spa"))

      expect(validated).to be_valid
      expect(validated.parsed_params).to eq("amenity" => %w[pool spa])
    end

    it "reads a deepObject argument as the one-level object T-087 narrowed it to" do
      validated = definition.validate_request(request("GET", "/search_hotels?filter%5Bcity%5D=Dublin"))

      expect(validated).to be_valid
      expect(validated.parsed_params).to eq("filter" => { "city" => "Dublin" })
    end

    it "accepts the INJECTED `limit`/`cursor` that no input_schema declares" do
      validated = definition.validate_request(request("GET", "/search_hotels?limit=5&cursor=b2Zmc2V0OjQw"))

      expect(validated).to be_valid
      expect(validated.parsed_params).to eq("limit" => 5, "cursor" => "b2Zmc2V0OjQw")
    end

    it "refuses an argument the declared schema refuses" do
      expect(definition.validate_request(request("GET", "/search_hotels?min_stars=four")))
        .not_to be_valid
      expect(definition.validate_request(request("GET", "/search_hotels?neighbourhood=Dublin")))
        .not_to be_valid
    end

    it "accepts BOTH shapes a paginating query answers with, through the hoisted $defs" do
      call = request("GET", "/search_hotels")

      expect(definition.validate_response(call, response(200, [{ "property_id" => 4 }])))
        .to be_valid
      expect(definition.validate_response(
               call, response(200, { "rows" => [{ "property_id" => 4 }], "next" => "b2Zmc2V0OjQw" })
             )).to be_valid
    end

    it "rejects an answer the declared output_schema does not allow" do
      expect(definition.validate_response(request("GET", "/search_hotels"),
                                          response(200, { "property_id" => 4 })))
        .not_to be_valid
    end

    it "accepts a real problem document and rejects an off-vocabulary code" do
      call    = request("GET", "/search_hotels")
      problem = Kiosk::Server::Errors::NotFound.new("no such hotel", hint: "call schema").to_problem

      expect(definition.validate_response(
               call, response(404, problem, content_type: Kiosk::Server::Errors::PROBLEM_CONTENT_TYPE)
             )).to be_valid
      expect(definition.validate_response(
               call,
               response(404, problem.merge(code: "teapot"),
                        content_type: Kiosk::Server::Errors::PROBLEM_CONTENT_TYPE)
             )).not_to be_valid
    end

    it "does NOT understand the `a%5B%5D=` spelling the skill teaches, and that is recorded rather than hidden" do
      # MEASURED, and it is the T-086 finding a porter has to know: a generic
      # OpenAPI validator sees `amenity[]` as an UNDECLARED parameter and
      # passes it over — the declared `amenity` is simply never validated.
      # Our own wire reads both spellings (Rack parses them identically), so
      # nothing is broken here; what it means is that a porter must put the
      # argument decoding AHEAD of any generic request validator, never behind
      # it. No document can express both forms — OAS has no style for the
      # bracket convention, and OAS 3.2 §4.12.7 declines to add one.
      validated = definition.validate_request(
        request("GET", "/search_hotels?amenity%5B%5D=pool&amenity%5B%5D=spa"),
      )

      expect(validated).to be_valid
      expect(validated.parsed_params).to eq({})
    end
  end
end
