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

# `emit` — the one line an operator writes at the transition (T-169 phase A
# task 2). The scope it takes is the OPERATOR's answer to "who may read this",
# computed where the domain knows it; `reach` authorises a SUBSCRIPTION and is a
# different question, answered at the socket.
RSpec.describe "Kiosk::Server::Events.emit" do
  let(:controller) { Class.new(ApplicationController) { include Kiosk::Handler } }
  let(:store) { Kiosk::Server::EventStore.new }

  before do
    Kiosk.configure { |c| c.event_store = store }
    controller.class_eval do
      topic :delivery do
        description "Your order moved."
        payload_schema type: "object"
      end
    end
  end

  it "appends one event per identity in scope and returns the last id" do
    id = Kiosk::Server::Events.emit(
      topic: :delivery, subject: "ord_1", identity_scope: %w[u1 u2],
      data: { "status" => "dispatched" },
    )

    expect(store.since("u1", 0).first).to include(
      "topic" => "delivery", "subject" => "ord_1", "data" => { "status" => "dispatched" }
    )
    expect(store.since("u2", 0).length).to eq(1)
    expect(id).to eq(store.head)
  end

  it "stamps occurred_at as ISO 8601 UTC when the caller gives none" do
    Kiosk::Server::Events.emit(topic: :delivery, subject: nil, identity_scope: %w[u1], data: {})

    expect(store.since("u1", 0).first["occurred_at"]).to match(/\A\d{4}-\d{2}-\d{2}T[\d:]+Z\z/)
  end

  it "honours an occurred_at the caller supplies, rendered the same way" do
    Kiosk::Server::Events.emit(
      topic: :delivery, subject: nil, identity_scope: %w[u1], data: {},
      occurred_at: Time.utc(2026, 9, 25, 11, 4, 18),
    )

    expect(store.since("u1", 0).first["occurred_at"]).to eq("2026-09-25T11:04:18Z")
  end

  it "carries the five closed members and no others" do
    Kiosk::Server::Events.emit(topic: :delivery, subject: "ord_1", identity_scope: %w[u1], data: {})

    expect(store.since("u1", 0).first.keys)
      .to contain_exactly("id", "topic", "subject", "occurred_at", "data")
  end

  it "accepts a nil subject — a topic with no subject says so" do
    Kiosk::Server::Events.emit(topic: :delivery, subject: nil, identity_scope: %w[u1], data: {})

    expect(store.since("u1", 0).first["subject"]).to be_nil
  end

  it "refuses a topic nobody declared, rather than inventing one on the wire" do
    expect {
      Kiosk::Server::Events.emit(topic: :nope, subject: nil, identity_scope: %w[u1], data: {})
    }.to raise_error(ArgumentError, /not a declared topic/)
  end

  it "writes nothing when the scope is empty" do
    Kiosk::Server::Events.emit(topic: :delivery, subject: nil, identity_scope: [], data: {})

    expect(store.head).to eq(0)
  end

  it "defaults the store to the in-process one" do
    Kiosk.reset!

    expect(Kiosk.configuration.event_store).to be_a(Kiosk::Server::EventStore)
  end
end
