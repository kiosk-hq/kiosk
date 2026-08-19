# frozen_string_literal: true

# The 0.4 query-argument encoding, as decided by Phil in T-070 (option B,
# 2026-08-17) and narrowed in T-087 (option A, 2026-08-19). The TODO.md
# `T-070` row is the normative text these examples encode until both specs are
# rewritten; each `describe` below names the clause it covers.
#
# Every example here is a unit example: {Kiosk::Server::ArgumentDecoder} takes
# a query string and a declaration and returns arguments, with no Rails and no
# wire in the way. The wire-level half — that a real `GET <endpoint>/<verb>`
# reaches it, and that a refusal comes back as a 400 envelope — is
# `verb_controller_spec.rb`.

RSpec.describe Kiosk::Server::ArgumentDecoder do
  def decode(query_string, schema = nil)
    described_class.decode(query_string, input_schema: schema)
  end

  # A declaration in the shape the `input_schema` macro produces: symbol keys.
  # No keyword parameters, deliberately — with any, Ruby would route a call
  # like `schema(min_stars: {…})` into them instead of into `properties`.
  def schema(properties)
    { type: "object", additionalProperties: false, properties: properties }
  end

  describe "rule (2) — scalars are name=value, percent-decoded UTF-8" do
    it "decodes a percent-encoded non-ASCII string to its characters" do
      expect(decode("neighbourhood=Be%C5%9Fikta%C5%9F")).to eq(neighbourhood: "Beşiktaş")
    end

    it "leaves an undeclared parameter as the String the wire sent" do
      expect(decode("anything=4", schema({}))).to eq(anything: "4")
    end
  end

  describe "rule (3) — the two array spellings agree, and a bare repeat is not one" do
    let(:declared) { schema(amenity: { type: "array", items: { type: "string" } }) }

    it "decodes the PERCENT-ENCODED bracket spelling — the wire form" do
      expect(decode("amenity%5B%5D=pool&amenity%5B%5D=spa", declared))
        .to eq(amenity: %w[pool spa])
    end

    it "decodes the RAW bracket spelling to exactly the same thing" do
      expect(decode("amenity[]=pool&amenity[]=spa", declared))
        .to eq(decode("amenity%5B%5D=pool&amenity%5B%5D=spa", declared))
    end

    it "keeps Rack's last-wins for a repeated name with NO array declared" do
      # The server MUST NOT invent an array. Rack keeps the last value and so
      # do we — measured on the shipped Rack 3.2.6:
      # parse_nested_query("a=1&a=2") => {"a" => "2"}.
      expect(decode("amenity=pool&amenity=spa")).to eq(amenity: "spa")
      expect(decode("amenity=pool&amenity=spa", schema(amenity: { type: "string" })))
        .to eq(amenity: "spa")
    end

    it "folds a bare repeat into an array ONLY where the schema declares one" do
      # Not invention: the declared type resolves the ambiguity Rack resolves
      # by last-wins, which is the same thing coercing "4" to 4 does. Both
      # values survive — dropping one would be a silent data loss.
      expect(decode("amenity=pool&amenity=spa", declared)).to eq(amenity: %w[pool spa])
    end

    it "wraps a single bare value where an array is declared" do
      expect(decode("amenity=pool", declared)).to eq(amenity: %w[pool])
    end

    it "refuses a name used as both scalar and array in one query string" do
      expect { decode("amenity=pool&amenity%5B%5D=spa", declared) }
        .to raise_error(Kiosk::Server::Errors::BadRequest, /amenity/)
    end
  end

  describe "rule (4) — objects are ONE level with SCALAR leaves (T-087's narrowing)" do
    let(:declared) do
      schema(price: { type: "object",
                      properties: { min_cents: { type: "integer" }, max_cents: { type: "integer" } } })
    end

    it "decodes one level of object, in either spelling" do
      expect(decode("price%5Bmin_cents%5D=8000&price%5Bmax_cents%5D=20000", declared))
        .to eq(price: { min_cents: 8000, max_cents: 20_000 })
      expect(decode("price[min_cents]=8000", declared)).to eq(price: { min_cents: 8000 })
    end

    it "REFUSES an array-valued object leaf — the shape T-087 dropped" do
      # `o[k][]=v` was normative under T-070-B for two days and is not any
      # more: it is expressible in no OpenAPI style and broke four of the
      # twelve surveyed validators.
      expect { decode("price%5Bmin_cents%5D%5B%5D=8000") }
        .to raise_error(Kiosk::Server::Errors::BadRequest, /price.*array-valued leaf/m)
    end

    it "REFUSES two levels of nesting — that read is an ACTION (rule 5)" do
      expect { decode("price%5Brange%5D%5Bmin%5D=8000") }
        .to raise_error(Kiosk::Server::Errors::BadRequest, /price.*nests two levels/m)
    end

    it "REFUSES an array of objects — that read is an ACTION too" do
      expect { decode("items%5B%5D%5Bsku%5D=milk&items%5B%5D%5Bqty%5D=2") }
        .to raise_error(Kiosk::Server::Errors::BadRequest, /items.*array of objects/m)
    end

    it "names the ACTION remedy in the hint rather than only refusing" do
      decode("price%5Brange%5D%5Bmin%5D=8000")
    rescue Kiosk::Server::Errors::BadRequest => e
      expect(e.hint).to match(/ACTION/)
    end
  end

  describe "rule (6) — types come from input_schema, before the handler runs" do
    it "recovers an integer" do
      expect(decode("min_stars=4", schema(min_stars: { type: "integer" }))).to eq(min_stars: 4)
    end

    it "recovers a number" do
      expect(decode("rate=4.5", schema(rate: { type: "number" }))).to eq(rate: 4.5)
    end

    it "recovers both boolean literals" do
      declared = schema(open_now: { type: "boolean" })
      expect(decode("open_now=true",  declared)).to eq(open_now: true)
      expect(decode("open_now=false", declared)).to eq(open_now: false)
    end

    it "keeps a declared string a string, and checks a declared date format" do
      declared = schema(date: { type: "string", format: "date" })
      expect(decode("date=2026-08-19", declared)).to eq(date: "2026-08-19")
    end

    it "coerces each element of a declared array of integers" do
      declared = schema(ids: { type: "array", items: { type: "integer" } })
      expect(decode("ids%5B%5D=1&ids%5B%5D=2", declared)).to eq(ids: [1, 2])
    end

    it "coerces the leaves of a declared object" do
      declared = schema(price: { type: "object", properties: { min_cents: { type: "integer" } } })
      expect(decode("price%5Bmin_cents%5D=8000", declared)).to eq(price: { min_cents: 8000 })
    end

    it "takes the first non-null member of a nullable union" do
      declared = schema(min_stars: { type: %w[integer null] })
      expect(decode("min_stars=4", declared)).to eq(min_stars: 4)
    end

    it "reads a string-keyed declaration the same as a symbol-keyed one" do
      declared = { "type" => "object", "properties" => { "min_stars" => { "type" => "integer" } } }
      expect(decode("min_stars=4", declared)).to eq(min_stars: 4)
    end
  end

  describe "rule (6) — a value that will not coerce is a 400 NAMING the parameter" do
    def refusal(query_string, declared)
      decode(query_string, declared)
      raise "expected a refusal"
    rescue Kiosk::Server::Errors::BadRequest => e
      e
    end

    it "refuses a non-integer where an integer is declared" do
      e = refusal("min_stars=four", schema(min_stars: { type: "integer" }))
      expect(e.message).to include("min_stars")
      expect(e.http_status).to eq(400)
      expect(e.code).to eq("bad_request")
    end

    it "refuses a float where an integer is declared" do
      expect(refusal("min_stars=4.5", schema(min_stars: { type: "integer" })).message)
        .to include("min_stars")
    end

    it "refuses a non-number where a number is declared" do
      expect(refusal("rate=cheap", schema(rate: { type: "number" })).message).to include("rate")
    end

    it "refuses a boolean spelling that is not one of the two literals" do
      # `1`, `on` and `yes` are Rails idioms, not wire spellings — accepting
      # them would put a second boolean grammar on a published wire.
      declared = schema(open_now: { type: "boolean" })
      %w[1 on yes TRUE].each do |spelling|
        expect(refusal("open_now=#{spelling}", declared).message).to include("open_now")
      end
    end

    it "refuses a malformed date where format: date is declared" do
      declared = schema(date: { type: "string", format: "date" })
      ["2026-13-01", "19-08-2026", "2026-8-1", "tomorrow"].each do |spelling|
        expect(refusal("date=#{spelling}", declared).message).to include("date")
      end
    end

    it "refuses a malformed timestamp where format: date-time is declared" do
      declared = schema(slot: { type: "string", format: "date-time" })
      expect(refusal("slot=soon", declared).message).to include("slot")
    end

    it "refuses an EMPTY value where a scalar type is declared" do
      # ABSENT ≠ EMPTY: `?min_stars=` IS present, and the empty string is not
      # an integer, so it is a refusal rather than a silently-absent filter.
      expect(refusal("min_stars=", schema(min_stars: { type: "integer" })).message)
        .to include("min_stars")
    end

    it "refuses an array where a scalar is declared" do
      expect(refusal("min_stars%5B%5D=4", schema(min_stars: { type: "integer" })).message)
        .to include("min_stars")
    end

    it "refuses an object where an array is declared" do
      expect(refusal("ids%5Ba%5D=1", schema(ids: { type: "array" })).message).to include("ids")
    end

    it "refuses a scalar where an object is declared" do
      expect(refusal("price=cheap", schema(price: { type: "object" })).message).to include("price")
    end

    it "names the offending element of a declared array" do
      declared = schema(ids: { type: "array", items: { type: "integer" } })
      expect(refusal("ids%5B%5D=1&ids%5B%5D=two", declared).message).to include("ids[1]")
    end
  end

  describe "rule (7) — limit and cursor are reserved, always accepted, never declared" do
    it "coerces limit to an integer on a verb that declares neither" do
      # getgrocery's `catalog` is exactly this: a closed empty object. Without
      # the reserved rule the `?limit=` the pagination contract invites would
      # be undecodable on the very verbs that paginate.
      expect(decode("limit=20", schema({}))).to eq(limit: 20)
    end

    it "keeps cursor an opaque string" do
      expect(decode("cursor=eyJvIjoyMH0", schema({}))).to eq(cursor: "eyJvIjoyMH0")
    end

    it "refuses a non-integer limit, naming it" do
      expect { decode("limit=many", schema({})) }
        .to raise_error(Kiosk::Server::Errors::BadRequest, /limit/)
    end

    it "lets a verb that DOES declare limit constrain it itself" do
      declared = schema(limit: { type: "string" })
      expect(decode("limit=20", declared)).to eq(limit: "20")
    end
  end

  describe "rule (8) — ABSENT is not EMPTY" do
    it "decodes an explicitly empty value to the empty string under its key" do
      result = decode("title=")
      expect(result).to have_key(:title)
      expect(result[:title]).to eq("")
    end

    it "leaves a name that was never sent out of the hash entirely" do
      expect(decode("")).not_to have_key(:title)
      expect(decode(nil)).to eq({})
    end

    it "distinguishes the two on a verb that asks the presence question" do
      # Two live QUERIES ask it today — atablefor's `availability` and
      # getgrocery's `delivery_slots` both branch on `params.key?` — so this
      # rule binds shipped GET surfaces, not hypothetical ones.
      expect(decode("party_size=").key?(:party_size)).to be(true)
      expect(decode("other=1").key?(:party_size)).to be(false)
    end
  end

  describe "the refusals Rack itself raises" do
    it "answers Rack's own nesting-depth limit with a 400 rather than a 500" do
      # Rack::QueryParser::QueryLimitError is a Rack::BadRequest, like the
      # scalar-vs-array conflict above; both mean the same thing on the wire
      # and neither may escape as an uncaught 500.
      deep = "a#{"%5Bb%5D" * 40}=1"
      expect { decode(deep) }.to raise_error(Kiosk::Server::Errors::BadRequest)
    end
  end
end
