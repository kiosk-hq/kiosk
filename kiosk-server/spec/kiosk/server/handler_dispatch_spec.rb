# frozen_string_literal: true

# The callable the mixin puts in the registry (T-053). The operator-facing
# behaviour lives in handler_mixin_spec.rb; this covers what the seam does when
# the handler misbehaves, plus the reload property the whole design rests on.
#
# `ApplicationController` (the fake host base class) is defined in spec_helper.rb.

require "rack/mock"
require "json"

# A NAMED handler class — the reload test needs one, because a named class is
# held in the registry by name and re-resolved on every call, while an anonymous
# one can only be held directly.
class SpecReloadableController < ApplicationController
  include Kiosk::Handler

  kind :query
  description "Lists the shop's stock."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  output_schema true
  def reloadable = render(json: [{ "sku" => "ORIGINAL" }])
end

RSpec.describe Kiosk::Server::HandlerDispatch do
  let(:identity)   { build_identity(user_id: "u-1", agent_id: "a-1") }
  let(:connection) { FakeConnection.new }

  # The wire NAME is its own argument — a path segment on the 0.4 wire, never
  # a body field — so it is lifted out of `args` here exactly as
  # {Kiosk::Server::VerbController} lifts it out of `params[:kiosk_verb]`.
  def execute(kind, args)
    args = args.dup
    name = (args.delete(:name) || args.delete("name")).to_s
    Kiosk::Server::CurrentRequest.with(identity: identity) do
      Kiosk::Server::Executor.call(kind: kind, args: args, identity: identity,
                                   connection: connection, name: name.empty? ? nil : name)
    end
  end

  describe "reload safety" do
    before { SpecReloadableController.kiosk_register! }

    it "holds a named controller by NAME, so a reloaded class is picked up" do
      handler = Kiosk::Server::Queries.fetch("reloadable")
      expect(handler.controller_name).to eq("SpecReloadableController")
      expect(execute(:query, { name: "reloadable" }).payload).to eq([{ "sku" => "ORIGINAL" }])

      # What Zeitwerk does on a code reload: same constant, new class object.
      reloaded = Class.new(ApplicationController) do
        include Kiosk::Handler
        kind :query
        description "The edited handler."
        input_schema type: "object", additionalProperties: false, properties: {}, required: []
        output_schema true
        def reloadable = render(json: [{ "sku" => "EDITED" }])
      end
      stub_const("SpecReloadableController", reloaded)

      expect(execute(:query, { name: "reloadable" }).payload).to eq([{ "sku" => "EDITED" }])
    end

    it "answers not_found when the controller constant is gone" do
      hide_const("SpecReloadableController")

      expect { execute(:query, { name: "reloadable" }) }
        .to raise_error(Kiosk::Server::Errors::VerbNotFound, /is not loaded/)
    end
  end

  describe "a handler that does not answer with JSON" do
    it "fails loudly rather than putting HTML on the wire" do
      klass = Class.new(ApplicationController) do
        include Kiosk::Handler
        kind :query
        description "Renders HTML, which the wire cannot carry."
        input_schema type: "object", additionalProperties: false, properties: {}, required: []
        output_schema true
        def html_query = render(html: "<p>nope</p>".html_safe)
      end
      stub_const("SpecHtmlController", klass)

      expect { execute(:query, { name: "html_query" }) }
        .to raise_error(Kiosk::Server::Errors::ActionFailed, /non-JSON body/)
    end

    it "reports an unmapped status rather than guessing a wire code" do
      # 402 is three different wire codes (pow_required, payment_setup_required,
      # payment_failed); the seam refuses to pick one. A handler that means a
      # specific 402 raises the Errors class.
      klass = Class.new(ApplicationController) do
        include Kiosk::Handler
        kind :action
        description "Renders a bare 402."
        input_schema type: "object", additionalProperties: false, properties: {}, required: []
        output_schema true
        def bare_402 = render(json: { error: "pay up" }, status: :payment_required)
      end
      stub_const("SpecBare402Controller", klass)

      expect { execute(:run, { name: "bare_402" }) }
        .to raise_error(Kiosk::Server::Errors::ActionFailed, /pay up/)
    end

    it "falls back to the status when a rendered code does not belong to it" do
      # pow_required is a 402 code; rendered on a 403 it is a handler bug, and
      # the seam answers with what the status alone says rather than putting a
      # mislabelled code on the wire.
      klass = Class.new(ApplicationController) do
        include Kiosk::Handler
        kind :query
        description "Renders a 402 code on a 403 status."
        input_schema type: "object", additionalProperties: false, properties: {}, required: []
        output_schema true
        def mislabelled
          render json: { ok: false, error: { code: "pow_required", message: "nope" } },
                 status: :forbidden
        end
      end
      stub_const("SpecMislabelledController", klass)

      expect { execute(:query, { name: "mislabelled" }) }
        .to raise_error(Kiosk::Server::Errors::Base) { |e| expect(e.code).to eq("forbidden") }
    end

    it "never mistakes an operator's own code field for the wire vocabulary" do
      klass = Class.new(ApplicationController) do
        include Kiosk::Handler
        kind :action
        description "Answers a domain refusal with the app's own error code."
        input_schema type: "object", additionalProperties: false, properties: {}, required: []
        output_schema true
        def sold_out
          render json: { error: { code: "out_of_stock", message: "sold out" } }, status: :conflict
        end
      end
      stub_const("SpecSoldOutController", klass)

      expect { execute(:run, { name: "sold_out" }) }
        .to raise_error(Kiosk::Server::Errors::Base) { |e|
          expect(e.code).to eq("conflict")
          expect(e.message).to eq("sold out")
        }
    end

    it "rejects a page marker with no rows" do
      klass = Class.new(ApplicationController) do
        include Kiosk::Handler
        kind :query
        description "Sets the pagination marker by hand and renders the wrong shape."
        input_schema type: "object", additionalProperties: false, properties: {}, required: []
        output_schema true
        def bad_page
          request.env[Kiosk::Server::HandlerDispatch::PAGE_KEY] = true
          render json: { items: [] }
        end
      end
      stub_const("SpecBadPageController", klass)

      expect { execute(:query, { name: "bad_page" }) }
        .to raise_error(Kiosk::Server::Errors::ActionFailed, /rendered no rows/)
    end
  end

  describe "outside a wire request" do
    it "runs with no identity and no caller headers (the RLS journey case)" do
      klass = Class.new(ApplicationController) do
        include Kiosk::Handler
        kind :query
        description "Reports what it can see."
        input_schema type: "object", additionalProperties: false, properties: {}, required: []
        output_schema true
        def bare = render(json: { identity: kiosk_identity, ua: request.headers["User-Agent"] })
      end
      stub_const("SpecBareController", klass)

      result = Kiosk::Server::Queries.fetch("bare").call({})

      expect(result).to eq("identity" => nil, "ua" => nil)
    end
  end

  describe "an empty answer" do
    it "carries a bodiless 200 through as a nil value" do
      klass = Class.new(ApplicationController) do
        include Kiosk::Handler
        kind :action
        description "Acknowledges and returns nothing."
        input_schema type: "object", additionalProperties: false, properties: {}, required: []
        output_schema true
        def ack = head(:ok)
      end
      stub_const("SpecAckController", klass)

      expect(execute(:run, { name: "ack" }).payload).to be_nil
    end
  end
end
