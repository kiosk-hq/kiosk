# frozen_string_literal: true

class SpecRegistrationsQueriesController < ApplicationController
  include Kiosk::Handler

  kind :query
  description "Lists the board."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  output_schema true
  def spec_browse
    render json: []
  end
end

class SpecRegistrationsActionsController < ApplicationController
  include Kiosk::Handler

  kind :action
  description "Posts to the board."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  output_schema true
  def spec_post
    render json: {}
  end
end

class SpecRegistrationsDoomedController < ApplicationController
  include Kiosk::Handler

  kind :query
  description "A verb about to be deleted from its controller."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  output_schema true
  def spec_doomed
    render json: []
  end
end

RSpec.describe Kiosk::Server::HandlerRegistrations do
  let(:queries) { Kiosk::Server::Queries }
  let(:actions) { Kiosk::Server::Actions }

  around do |example|
    saved = described_class.handlers.dup
    described_class.handlers.clear
    example.run
  ensure
    described_class.handlers.replace(saved)
  end

  def register(*names)
    names.each { |name| described_class.handlers << name }
    described_class.reload!
  end

  describe ".add" do
    it "is called by include Kiosk::Handler" do
      klass = stub_const("SpecRegistrationsIncludedController", Class.new(ApplicationController))
      klass.include(Kiosk::Handler)

      expect(described_class.handlers).to include("SpecRegistrationsIncludedController")
    end
  end

  describe ".reload!" do
    it "registers the verbs of every handler, from an empty registry" do
      register("SpecRegistrationsQueriesController", "SpecRegistrationsActionsController")

      expect(queries.known).to contain_exactly("spec_browse")
      expect(actions.known).to contain_exactly("spec_post")
    end

    it "registers a handler the wire can reach" do
      register("SpecRegistrationsQueriesController")

      expect(queries.fetch("spec_browse")).to be_a(Kiosk::Server::HandlerDispatch)
      expect(queries.describe("spec_browse")[:description]).to eq("Lists the board.")
    end

    it "is idempotent" do
      register("SpecRegistrationsQueriesController")
      described_class.reload!

      expect(queries.known).to eq(["spec_browse"])
    end

    it "drops a verb the handler no longer declares" do
      register("SpecRegistrationsDoomedController")
      expect(queries.known).to eq(["spec_doomed"])

      SpecRegistrationsDoomedController.kiosk_declarations.delete("spec_doomed")
      described_class.reload!

      expect(queries.known).to be_empty
    end

    it "forgets a handler whose class no longer exists" do
      register("Kiosk::NoSuchController")

      expect(described_class.handlers).to be_empty
    end
  end

  describe "one name, one kind" do
    it "refuses a name declared as both a query and an action" do
      stub_const("SpecCollidingQueriesController", Class.new(ApplicationController) do
        include Kiosk::Handler
        kind :query
        description "A name two kinds want."
        input_schema type: "object"
        output_schema true
        def spec_collide = render(json: [])
      end)
      stub_const("SpecCollidingActionsController", Class.new(ApplicationController) do
        include Kiosk::Handler
        kind :action
        description "The same name, the other kind."
        input_schema type: "object"
        output_schema true
        def spec_collide = render(json: {})
      end)

      expect { register("SpecCollidingQueriesController", "SpecCollidingActionsController") }
        .to raise_error(Kiosk::Server::Errors::ConfigurationError, /spec_collide.*BOTH a query and an action/m)
    end
  end

  describe ".clear!" do
    it "empties both registries" do
      register("SpecRegistrationsQueriesController", "SpecRegistrationsActionsController")
      expect(queries.known).not_to be_empty
      expect(actions.known).not_to be_empty

      described_class.clear!

      expect(queries.known).to be_empty
      expect(actions.known).to be_empty
    end
  end
end

RSpec.describe "the registries' #unregister" do
  it "removes the entry so the wire stops serving it" do
    declare_query("gone")

    expect(Kiosk::Server::Queries.unregister("gone")).to be_a(Kiosk::Server::Queries::Entry)
    expect(Kiosk::Server::Queries.known).to be_empty
    expect { Kiosk::Server::Queries.fetch("gone") }.to raise_error(Kiosk::Server::Errors::VerbNotFound)
  end

  it "is a no-op for a name that was never registered" do
    expect(Kiosk::Server::Actions.unregister("never")).to be_nil
  end
end
