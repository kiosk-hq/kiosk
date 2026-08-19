# frozen_string_literal: true

# Response-shape validation (T-068 slice 3 / T-073 = A).
#
# `output_schema` is REQUIRED on every 0.4 verb and, with the envelope gone, it
# is the ONLY machine-readable statement of what a call returns. These examples
# are what stops it being a statement nothing checks: with
# `validate_responses` on, an answer that its own declaration rejects is a loud
# `action_failed`, not a lie handed to an assistant and republished by the
# derived OpenAPI document.
RSpec.describe Kiosk::Server::ResponseValidation do
  let(:connection) { FakeConnection.new }
  let(:identity)   { build_identity(actor: "agent") }

  def query(name, args = {})
    Kiosk::Server::Executor.call(kind: :query, args: args, name: name,
                                 identity: identity, connection: connection)
  end

  def action(name, args = {})
    Kiosk::Server::Executor.call(kind: :run, args: args, name: name,
                                 identity: identity, connection: connection)
  end

  describe "off by default" do
    it "does not check a payload its declaration rejects" do
      expect(Kiosk.configuration.validate_responses).to be(false)

      declare_query("menu", output_schema: { type: "array", items: { type: "string" } }) do
        render json: [{ id: 1 }]
      end

      expect(query("menu").payload).to eq([{ "id" => 1 }])
    end
  end

  describe "with validate_responses on" do
    before { Kiosk.configuration.validate_responses = true }

    it "passes a query whose rows satisfy the declared schema" do
      declare_query("menu", output_schema: {
                      type: "array",
                      items: { type: "object", additionalProperties: false,
                               properties: { id: { type: "integer" }, name: { type: "string" } },
                               required: %w[id name] },
                    }) { render json: [{ id: 1, name: "Margherita" }] }

      expect(query("menu").payload).to eq([{ "id" => 1, "name" => "Margherita" }])
    end

    it "refuses a query whose rows do NOT, naming the verb and the pointer" do
      declare_query("menu", output_schema: {
                      type: "array",
                      items: { type: "object", additionalProperties: false,
                               properties: { id: { type: "integer" } }, required: ["id"] },
                    }) { render json: [{ id: 1, surprise: true }] }

      expect { query("menu") }.to raise_error(Kiosk::Server::Errors::ActionFailed) { |e|
        expect(e.message).to include("query \"menu\"")
        expect(e.message).to include("output_schema")
        expect(e.message).to include("/0")
        expect(e.hint).to include("descriptor and the handler disagree")
      }
    end

    it "refuses an ACTION whose object does not satisfy its declared schema" do
      declare_action("place_order", output_schema: {
                       type: "object", additionalProperties: false,
                       properties: { order_id: { type: "string" } }, required: ["order_id"],
                     }) { render json: { order_id: 7 } }

      expect { action("place_order") }.to raise_error(Kiosk::Server::Errors::ActionFailed,
                                                      /action "place_order"/)
    end

    # THE SHAPE THE WIRE ANSWERS, not the one the handler wrote: a paginating
    # query renders `{rows:, next_cursor:, total:}` internally and the wire
    # publishes the ROWS — a bare array, the cursor and the total having left
    # as the `Link` and `X-Total-Count` response headers (T-092). The
    # declaration is checked against the PUBLISHED spelling, which is the whole
    # reason this hook sits on {Result#to_payload} rather than on what the
    # handler rendered. Before T-092 this example asserted the opposite shape;
    # that it had to be rewritten is the check doing its job.
    it "checks a paginating query against the PUBLISHED bare array" do
      schema = { type: "array", items: { type: "object" } }
      declare_query("search", output_schema: schema) do
        render_kiosk_page([{ id: 1 }], next_cursor: "b2Zmc2V0OjIw", total: 9)
      end

      expect(query("search").to_payload).to eq([{ "id" => 1 }])
    end

    # The corollary, and it is what the shape collapse BOUGHT: a paginating
    # verb's truncated page and its last page are the SAME shape now, so ONE
    # unbranched array schema describes both. The `oneOf` a paginating
    # descriptor used to need went with the object.
    it "accepts the same array schema on the last page of the same verb" do
      schema = { type: "array", items: { type: "object" } }
      declare_query("search", output_schema: schema) { render_kiosk_page([{ id: 1 }]) }

      expect(query("search").to_payload).to eq([{ "id" => 1 }])
    end

    # …and an object schema, which a paginating verb used to REQUIRE, is now
    # exactly what a paginating verb must not declare.
    it "refuses an object schema on a paginating verb" do
      object_only = { type: "object", required: %w[rows next] }
      declare_query("search", output_schema: object_only) do
        render_kiosk_page([{ id: 1 }], next_cursor: "b2Zmc2V0OjIw")
      end

      expect { query("search") }.to raise_error(Kiosk::Server::Errors::ActionFailed,
                                                /output_schema rejects/)
    end

    it "skips a verb that declares no output_schema at all" do
      # Not reachable through the mixin any more — it refuses such a
      # declaration — but the registry still takes nil, and the check must not
      # invent a contract where none was published.
      Kiosk::Server::Queries.declare("legacy", ->(_args) { [{ "id" => 1 }] })

      expect(query("legacy").payload).to eq([{ "id" => 1 }])
    end
  end
end
