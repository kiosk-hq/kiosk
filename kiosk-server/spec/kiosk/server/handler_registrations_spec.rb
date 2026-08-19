# frozen_string_literal: true

# {Kiosk::Server::HandlerRegistrations} — the rebuild the engine runs from
# `to_prepare`, which is what makes a mixin-declared verb reachable in an
# environment that does not eager-load (development). The end-to-end proof that
# the ENGINE drives it, across a real reload cycle in a booted app, is
# handler_registration_boot_spec.rb; this file pins the semantics.

# An operator's handler controllers — the consumer's side, as everywhere else in
# these specs. spec_helper resets both registries before each example, so
# nothing here is registered until the code under test registers it.
class SpecRegistrationsQueriesController < ApplicationController
  include Kiosk::Query

  description "Lists the board."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  output_schema true
  def spec_browse
    render json: []
  end
end

class SpecRegistrationsActionsController < ApplicationController
  include Kiosk::Action

  description "Posts to the board."
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  output_schema true
  def spec_post
    render json: {}
  end
end

# Used by ONE example, which deletes a declaration from it to stand in for a
# Zeitwerk reload that dropped a verb. Kept separate so the mutation cannot
# reach another example under a random seed.
class SpecRegistrationsDoomedController < ApplicationController
  include Kiosk::Query

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

  describe ".reload!" do
    it "registers the verbs of every declared handler, from an empty registry" do
      expect(queries.known).to be_empty
      expect(actions.known).to be_empty

      described_class.reload!(%w[SpecRegistrationsQueriesController SpecRegistrationsActionsController])

      expect(queries.known).to contain_exactly("spec_browse")
      expect(actions.known).to contain_exactly("spec_post")
    end

    it "registers a handler the wire can actually reach" do
      described_class.reload!(%w[SpecRegistrationsQueriesController])

      expect(queries.fetch("spec_browse")).to be_a(Kiosk::Server::HandlerDispatch)
      expect(queries.describe("spec_browse")[:description]).to eq("Lists the board.")
    end

    it "accepts a class but keeps only its NAME, so a reload cannot pin a stale generation" do
      described_class.reload!([SpecRegistrationsQueriesController])

      expect(queries.known).to contain_exactly("spec_browse")
    end

    it "is idempotent — running twice leaves one registration per verb" do
      2.times { described_class.reload!(%w[SpecRegistrationsQueriesController]) }

      expect(queries.known).to eq(["spec_browse"])
    end

    it "drops a verb the handler no longer declares" do
      described_class.reload!(%w[SpecRegistrationsDoomedController])
      expect(queries.known).to eq(["spec_doomed"])

      # What a Zeitwerk reload does: the next generation of the class declares
      # one verb fewer. The in-process suite has no reloader, so the missing
      # declaration is the faithful stand-in.
      SpecRegistrationsDoomedController.kiosk_declarations.delete("spec_doomed")
      described_class.reload!(%w[SpecRegistrationsDoomedController])

      expect(queries.known).to be_empty
    end

    it "registers nothing when no handlers are declared" do
      described_class.reload!([])

      expect(queries.known).to be_empty
      expect(actions.known).to be_empty
    end

    it "reads Kiosk.configuration.handlers when given no argument" do
      Kiosk.configure { |c| c.handlers = %w[SpecRegistrationsActionsController] }

      described_class.reload!

      expect(actions.known).to contain_exactly("spec_post")
    end

    it "refuses a name that does not resolve, naming the slot" do
      expect { described_class.reload!(%w[Kiosk::NoSuchController]) }
        .to raise_error(Kiosk::Server::Errors::ConfigurationError,
                        /handlers names "Kiosk::NoSuchController"/)
    end

    it "refuses a class that includes neither mixin" do
      expect { described_class.reload!(%w[ApplicationController]) }
        .to raise_error(Kiosk::Server::Errors::ConfigurationError,
                        /includes neither Kiosk::Action nor Kiosk::Query/)
    end

    it "refuses an anonymous class — it could not be re-resolved after a reload" do
      anonymous = Class.new(ApplicationController) { include Kiosk::Query }

      expect { described_class.reload!([anonymous]) }
        .to raise_error(Kiosk::Server::Errors::ConfigurationError, /anonymous class/)
    end
  end

  # ── ONE NAME, ONE KIND (§3.2) ────────────────────────────────────────────
  #
  # The collision is between two SEPARATE controller classes — a demo declares
  # its queries and its actions in different files, and must — so no class body
  # can see it. This pass has just rebuilt both registries from a cleared
  # state, which is the first moment the whole surface exists at once.
  describe "one name, one kind" do
    it "refuses a name declared as both a query and an action" do
      Object.const_set(:SpecCollidingQueriesController, Class.new(ApplicationController) do
        include Kiosk::Query
        description "A name two kinds want."
        input_schema type: "object"
        output_schema true
        def spec_collide = render(json: [])
      end)
      Object.const_set(:SpecCollidingActionsController, Class.new(ApplicationController) do
        include Kiosk::Action
        description "The same name, the other kind."
        input_schema type: "object"
        output_schema true
        def spec_collide = render(json: {})
      end)

      expect {
        described_class.reload!(%w[SpecCollidingQueriesController SpecCollidingActionsController])
      }.to raise_error(Kiosk::Server::Errors::ConfigurationError, /spec_collide.*BOTH a query and an action/m)
    ensure
      Object.send(:remove_const, :SpecCollidingQueriesController)
      Object.send(:remove_const, :SpecCollidingActionsController)
    end

    it "is silent when the two registries share no name" do
      expect {
        described_class.reload!(%w[SpecRegistrationsQueriesController SpecRegistrationsActionsController])
      }.not_to raise_error
    end
  end

  describe ".clear!" do
    it "empties both registries" do
      described_class.reload!(%w[SpecRegistrationsQueriesController SpecRegistrationsActionsController])
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
    expect { Kiosk::Server::Queries.fetch("gone") }.to raise_error(Kiosk::Server::Errors::NotFound)
  end

  it "is a no-op for a name that was never registered" do
    expect(Kiosk::Server::Actions.unregister("never")).to be_nil
  end
end
