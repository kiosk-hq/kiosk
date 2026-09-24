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
    controller.kiosk_register!

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
    controller.kiosk_register!

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
    controller.kiosk_register!

    verb = Kiosk::Server::Queries.describe("my_verb")
    expect(verb[:reach]).to eq("principal")
    expect(verb[:description]).to eq("A verb.")
  end

  # ── RELOAD, which is where the first spelling of this was wrong ──────────
  #
  # `topic` used to call `Events.register` from the class body, so the SECOND
  # read of that body — a Zeitwerk reload, or an eager load following a lazy
  # one — met its own first registration and raised «already declared on this
  # origin» at boot. Measured in e2e, where `db:seed` loads the controller
  # twice in one process. The declaration is held on the class now and drained
  # by `kiosk_register!`, exactly as a verb is.
  it "survives the class body being read twice, as every reload reads it" do
    declaring = lambda do
      controller.class_eval do
        topic :todo do
          description "A todo on a list you can reach changed."
          payload_schema type: "object", properties: { done: { type: "boolean" } }
        end
      end
      controller.kiosk_register!
    end

    declaring.call
    expect { declaring.call }.not_to raise_error
    expect(described_class.known).to eq(%w[todo])
  end

  # The other direction, and the reason the fix is a REBUILD rather than an
  # idempotent register: a registry that is only ever added to keeps serving a
  # topic whose declaration is gone.
  it "drops a topic that is no longer declared, on the next rebuild" do
    controller.class_eval do
      topic :todo do
        description "A todo on a list you can reach changed."
        payload_schema type: "object"
      end
    end
    controller.kiosk_register!
    expect(described_class.known).to eq(%w[todo])

    Kiosk::Server::HandlerRegistrations.clear!

    expect(described_class.known).to eq([])
  end

  # THE PROPERTY HOLDING THE DECLARATION ON THE CLASS ACTUALLY BUYS, and the one
  # neither example above asserts (K-1805). Re-registering an identical frozen
  # declaration is a no-op, and `clear!` empties the registry however the macro
  # wrote into it — so the cheaper spelling, `topic` calling `Events.register`
  # as the class body runs, passes both of them and looks equally green. What it
  # cannot do is survive a REBUILD. The engine's `to_prepare` drops all three
  # registries and re-derives them from `c.handlers`; a class body is NOT read
  # again on that pass, so a topic that only ever registered from the body would
  # be gone from the catalogue for the rest of the process. In an eager-loading
  # production boot that is every class, and the origin would serve an empty
  # `events` array while still emitting.
  it "re-registers its topics on a rebuild, with the class body never read again" do
    controller.class_eval do
      topic :todo do
        description "A todo on a list you can reach changed."
        payload_schema type: "object"
      end
    end
    controller.kiosk_register!
    expect(described_class.known).to eq(%w[todo])

    # What `to_prepare` does, in its order. Nothing re-reads the class body
    # between these two lines, which is the whole point of the example.
    Kiosk::Server::HandlerRegistrations.clear!
    controller.kiosk_register!

    expect(described_class.known).to eq(%w[todo])
    expect(described_class.fetch("todo")[:description])
      .to eq("A todo on a list you can reach changed.")
  end

  it "refuses a name that is not a legal wire name" do
    expect {
      controller.class_eval do
        topic "Todo" do
          description "x"
          payload_schema type: "object"
        end
      end
      controller.kiosk_register!
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
      controller.kiosk_register!
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
      controller.kiosk_register!
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
      controller.kiosk_register!
    }.to raise_error(ArgumentError, /payload_schema/)
  end

  it "requires description" do
    expect {
      controller.class_eval do
        topic :todo do
          payload_schema type: "object"
        end
      end
      controller.kiosk_register!
    }.to raise_error(ArgumentError, /description/)
  end

  it "refuses a second declaration of the same name" do
    controller.class_eval do
      topic :todo do
        description "x"
        payload_schema type: "object"
      end
    end
    controller.kiosk_register!

    expect {
      controller.class_eval do
        topic :todo do
          description "y"
          payload_schema type: "object"
        end
      end
      controller.kiosk_register!
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
    controller.kiosk_register!

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
    controller.kiosk_register!

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
    controller.kiosk_register!

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
    controller.kiosk_register!
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

# The events surface as an operator and an assistant SEE it: a third catalogue
# array, a fifth capability, and a discovery field (T-169 phase A task 4).
RSpec.describe "the events surface in the catalogue and discovery" do
  let(:controller) { Class.new(ApplicationController) { include Kiosk::Handler } }

  def declare_topic!
    controller.class_eval do
      topic :todo do
        description "A todo on a list you can reach changed."
        payload_schema type: "object", properties: { done: { type: "boolean" } }
      end
    end
    controller.kiosk_register!
  end

  def declare_verb!
    controller.class_eval do
      kind :query
      description "Lists things."
      input_schema type: "object", additionalProperties: false, properties: {}
      output_schema type: "array", items: { type: "object" }
      def list_things
        render json: []
      end
    end
    controller.kiosk_register!
  end

  describe "GET <endpoint>/schema" do
    it "publishes an events array beside queries and actions" do
      declare_topic!

      document = Kiosk::Server::SchemaDocument.document
      expect(document[:events].map { |e| e[:name] }).to eq(%w[todo])
    end

    it "publishes an EMPTY events array on an origin that declares no topic" do
      declare_verb!

      document = Kiosk::Server::SchemaDocument.document
      expect(document[:events]).to eq([])
    end

    # The catalogue is cacheable for a YEAR at its digest-bearing URL, so a
    # topic that does not move the digest is a topic no cached client ever
    # learns about.
    it "moves the digest when a topic is declared" do
      declare_verb!
      before_digest = Kiosk::Server::SchemaDocument.digest
      declare_topic!
      after_digest = Kiosk::Server::SchemaDocument.digest

      expect(after_digest).not_to eq(before_digest)
    end
  end

  describe "capabilities" do
    it "gains `events` when a topic is registered, last in the canonical order" do
      declare_verb!
      declare_topic!

      expect(Kiosk.configuration.capabilities).to eq(%w[schema queries events])
    end

    it "does NOT advertise events on an origin that declares no topic" do
      declare_verb!

      expect(Kiosk.configuration.capabilities).not_to include("events")
    end

    # An explicit list is returned verbatim — the override the accessor already
    # documents, and a fifth member must not start overriding the override.
    it "leaves an operator's explicit list alone" do
      declare_topic!
      Kiosk.configure { |c| c.capabilities = %w[schema queries] }

      expect(Kiosk.configuration.capabilities).to eq(%w[schema queries])
    end
  end

  describe "/.well-known/kiosk.json" do
    before { Kiosk.configure { |c| c.issuer = "https://shop.example" } }

    it "carries events_url when a topic is registered" do
      declare_topic!

      built = Kiosk::Server::WellKnown.build(base_url: "https://shop.example")
      expect(built[:kiosk][:events_url]).to eq("wss://shop.example/kiosk/events")
    end

    it "omits events_url entirely when no topic is registered" do
      built = Kiosk::Server::WellKnown.build(base_url: "https://shop.example")

      expect(built[:kiosk]).not_to have_key(:events_url)
    end
  end
end
