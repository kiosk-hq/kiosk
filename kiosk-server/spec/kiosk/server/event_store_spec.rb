# frozen_string_literal: true

# The event-store CONTRACT, exercised through its in-process implementation
# (T-169 phase A task 2).
#
# This is the TEST implementation of the seam. It IS what
# `Kiosk.configuration.event_store` falls back to when an operator sets
# nothing, and it is never what a DEPLOYED origin may run on:
# {Kiosk::Server::EventStores::ActiveRecord} is what the generator writes, and
# a production origin that declares a topic and leaves this default in place
# does not boot ({Kiosk::Server::Engine.ephemeral_event_store_error}). Two of the eight topics
# (`delivery`, `todo`) are read back ACROSS sessions through the cursor rather
# than over a held socket, so a tail that dies on restart makes those
# unanswerable rather than degraded. What is asserted here is the contract both
# implementations answer; the ActiveRecord suite asserts the same properties
# against a real table.

RSpec.describe Kiosk::Server::EventStore do
  subject(:store) { described_class.new }

  def event(topic: "todo", subject: "l1", data: { "done" => true })
    { "topic" => topic, "subject" => subject, "data" => data,
      "occurred_at" => "2026-09-25T10:00:00Z" }
  end

  # ONE counter for the whole origin, not one per identity and not one per
  # topic: that is what lets a single cursor resume every subscription on a
  # socket with one integer comparison.
  it "assigns ids that are monotonic per ORIGIN" do
    first  = store.append("u1", event)
    second = store.append("u2", event(topic: "delivery"))
    third  = store.append("u1", event)

    expect([first, second, third]).to eq([1, 2, 3])
    expect(store.head).to eq(3)
  end

  it "returns only events after the cursor, for that identity only" do
    first = store.append("u1", event(data: { "n" => 1 }))
    store.append("u2", event(data: { "n" => 2 }))
    third = store.append("u1", event(data: { "n" => 3 }))

    expect(store.since("u1", 0).map { |e| e["id"] }).to eq([first, third])
    expect(store.since("u1", first).map { |e| e["id"] }).to eq([third])
    expect(store.since("u1", first).first["data"]).to eq("n" => 3)
  end

  it "stamps the assigned id into the event it hands back" do
    id = store.append("u1", event)

    expect(store.since("u1", 0).first["id"]).to eq(id)
  end

  it "does not mutate the event the caller passed in" do
    original = event
    store.append("u1", original)

    expect(original).not_to have_key("id")
  end

  it "answers head 0 and an empty tail on a fresh origin" do
    expect(store.head).to eq(0)
    expect(store.since("u1", 0)).to eq([])
  end

  # "I cannot prove you saw everything" — the one condition that makes a client
  # re-read current state through the ordinary verb, once.
  it "reports truncated when the cursor predates what it still holds" do
    store.append("u1", event)
    second = store.append("u1", event)
    store.prune_before(second)

    expect(store.truncated?("u1", 0)).to be(true)
    expect(store.truncated?("u1", second)).to be(false)
  end

  it "is NOT truncated at head, even with nothing stored" do
    expect(store.truncated?("u1", 0)).to be(false)

    id = store.append("u1", event)
    expect(store.truncated?("u1", id)).to be(false)
  end

  it "keeps identities apart — one identity's tail is not another's" do
    store.append("u1", event)

    expect(store.since("u2", 0)).to eq([])
  end
end
