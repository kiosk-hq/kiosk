# frozen_string_literal: true

# The topic registry — the events half of what {Kiosk::Server::Queries} and
# {Kiosk::Server::Actions} are for verbs (T-169 phase A task 1).
#
# Written from the OPERATOR's side, like handler_mixin_spec.rb beside it: every
# example declares a topic the way a demo will and then reads the registry the
# catalogue reads. Nothing calls the mixin's internals.

RSpec.describe Kiosk::Server::Events do
  # An operator's own controller. `topic` needs no method of its own, but the
  # leak example below defines a verb, and that needs a real controller base.
  let(:controller) { Class.new(ApplicationController) { include Kiosk::Handler } }

  it "registers a topic declared with a block" do
    controller.class_eval do
      topic :todo do
        reach :consented
        description "A todo on a list you can reach changed."
        payload_schema type: "object", properties: { done: { type: "boolean" } }
        subject_reachable ->(subject, identity) { subject == identity[:user_id] }
      end
    end

    decl = described_class.fetch("todo")
    expect(decl[:reach]).to eq(:consented)
    expect(decl[:description]).to eq("A todo on a list you can reach changed.")
    expect(decl[:payload_schema]).to eq(type: "object", properties: { done: { type: "boolean" } })
    expect(decl[:subject_reachable].call("u1", { user_id: "u1" })).to be(true)
  end

  it "defaults reach to :principal, exactly as a verb does" do
    controller.class_eval do
      topic :order_payment do
        description "Your order was paid."
        payload_schema type: "object"
      end
    end

    expect(described_class.fetch("order_payment")[:reach]).to eq(:principal)
  end

  # THE REASON `topic` TAKES A BLOCK. `reach` and `description` write into
  # `kiosk_pending`, which `method_added` drains onto the NEXT method defined in
  # the class — so a flat `topic :todo` followed by bare macros would attach the
  # topic's reach and prose to whatever verb came after it, silently.
  it "does NOT leak its declarations onto the next method defined" do
    controller.class_eval do
      topic :todo do
        reach :consented
        description "A topic."
        payload_schema type: "object"
      end

      kind :query
      description "A verb."
      input_schema type: "object", additionalProperties: false, properties: {}
      output_schema type: "array", items: { type: "object" }
      def my_verb
        render json: []
      end
    end

    verb = Kiosk::Server::Queries.describe("my_verb")
    expect(verb[:reach]).to eq("principal")
    expect(verb[:description]).to eq("A verb.")
  end

  it "refuses a name that is not a legal wire name" do
    expect {
      controller.class_eval do
        topic "Todo" do
          description "x"
          payload_schema type: "object"
        end
      end
    }.to raise_error(ArgumentError, /not a legal Kiosk name/)
  end

  it "refuses a name the engine itself draws" do
    expect {
      controller.class_eval do
        topic :schema do
          description "x"
          payload_schema type: "object"
        end
      end
    }.to raise_error(ArgumentError, /reserved/)
  end

  it "refuses a reach that is not one of the four" do
    expect {
      controller.class_eval do
        topic :todo do
          reach :everyone
          description "x"
          payload_schema type: "object"
        end
      end
    }.to raise_error(ArgumentError, /not a Kiosk reach/)
  end

  # REQUIRED for the reason `output_schema` is required on a verb: without it a
  # message cannot be consumed without receiving one and observing what arrived.
  it "requires payload_schema" do
    expect {
      controller.class_eval do
        topic :todo do
          description "x"
        end
      end
    }.to raise_error(ArgumentError, /payload_schema/)
  end

  it "requires description" do
    expect {
      controller.class_eval do
        topic :todo do
          payload_schema type: "object"
        end
      end
    }.to raise_error(ArgumentError, /description/)
  end

  it "refuses a second declaration of the same name" do
    controller.class_eval do
      topic :todo do
        description "x"
        payload_schema type: "object"
      end
    end

    expect {
      controller.class_eval do
        topic :todo do
          description "y"
          payload_schema type: "object"
        end
      end
    }.to raise_error(ArgumentError, /already declared/)
  end

  it "projects a catalogue sorted by name, keyed exactly as a verb descriptor is" do
    controller.class_eval do
      topic :todo do
        description "T."
        payload_schema type: "object"
      end

      topic :delivery do
        description "D."
        payload_schema type: "object"
      end
    end

    expect(described_class.catalog.map { |e| e[:name] }).to eq(%w[delivery todo])
    expect(described_class.catalog.first.keys)
      .to contain_exactly(:name, :description, :reach, :payload_schema)
  end

  # `subject_reachable` is the operator's authorisation rule, not a fact about
  # the wire. Publishing the predicate would tell a caller how to look for a gap
  # in it, and a subscriber cannot act on it either way.
  it "keeps subject_reachable OUT of the published catalogue" do
    controller.class_eval do
      topic :todo do
        description "T."
        payload_schema type: "object"
        subject_reachable ->(_subject, _identity) { true }
      end
    end

    expect(described_class.catalog.first).not_to have_key(:subject_reachable)
  end

  it "knows the names it holds, sorted" do
    controller.class_eval do
      topic :todo do
        description "T."
        payload_schema type: "object"
      end

      topic :delivery do
        description "D."
        payload_schema type: "object"
      end
    end

    expect(described_class.known).to eq(%w[delivery todo])
  end
end
