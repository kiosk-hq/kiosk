# frozen_string_literal: true

require "spec_helper"

# The DURABLE event tail (T-169 phase A task 3).
#
# Same contract as spec/kiosk/server/event_store_spec.rb asserts against the
# in-process implementation, plus the two properties only a table can have:
# surviving the object that wrote the row, and a retention sweep on a clock.
RSpec.describe Kiosk::Server::EventStores::ActiveRecord do
  # Run against a real Postgres: a throwaway schema built from the shipped
  # `events_sql`, dropped afterwards. Connection comes from PG* env vars (CI's
  # service) or the local default socket; no reachable server → skip (never
  # fail) so DB-less machines stay green. Same shape as
  # pow_spent_stores_spec.rb.
  EVENTS_SPEC_SCHEMA = "kiosk_event_store_spec"

  def self.postgres_error
    @postgres_error ||= begin
      ::ActiveRecord::Base.establish_connection(
        adapter:  "postgresql",
        host:     ENV["PGHOST"],
        username: ENV["PGUSER"],
        password: ENV["PGPASSWORD"],
        database: ENV.fetch("PGDATABASE", "postgres"),
      )
      ::ActiveRecord::Base.connection.execute("SELECT 1")
      [false]
    rescue StandardError => e
      ["#{e.class}: #{e.message}"]
    end
    @postgres_error.first
  end

  before(:context) do
    skip "no local Postgres reachable (#{self.class.postgres_error})" if self.class.postgres_error

    conn = ::ActiveRecord::Base.connection
    conn.execute(%(DROP SCHEMA IF EXISTS "#{EVENTS_SPEC_SCHEMA}" CASCADE))
    conn.execute(%(CREATE SCHEMA "#{EVENTS_SPEC_SCHEMA}"))
    conn.execute(Kiosk::Server::SchemaDefinitions.events_sql(schema: EVENTS_SPEC_SCHEMA))
  end

  after(:context) do
    unless self.class.postgres_error
      ::ActiveRecord::Base.connection.execute(
        %(DROP SCHEMA IF EXISTS "#{EVENTS_SPEC_SCHEMA}" CASCADE),
      )
    end
  end

  subject(:store) { described_class.new }

  before do
    Kiosk.configure { |c| c.schema = EVENTS_SPEC_SCHEMA }
    ::ActiveRecord::Base.connection.execute(%(DELETE FROM "#{EVENTS_SPEC_SCHEMA}".events))
  end

  def event(topic: "todo", subject: "l1", data: { "done" => true })
    { "topic" => topic, "subject" => subject, "data" => data,
      "occurred_at" => "2026-09-25T10:00:00Z" }
  end

  # ── the contract, exactly as the in-process store answers it ──────────────

  it "assigns ids that are monotonic per ORIGIN, across identities and topics" do
    first  = store.append("u1", event)
    second = store.append("u2", event(topic: "delivery"))
    third  = store.append("u1", event)

    expect(second).to be > first
    expect(third).to be > second
    expect(store.head).to eq(third)
  end

  it "returns only events after the cursor, for that identity only" do
    first = store.append("u1", event(data: { "n" => 1 }))
    store.append("u2", event(data: { "n" => 2 }))
    third = store.append("u1", event(data: { "n" => 3 }))

    expect(store.since("u1", 0).map { |e| e["id"] }).to eq([first, third])
    expect(store.since("u1", first).map { |e| e["id"] }).to eq([third])
  end

  it "carries the five closed members and no others" do
    store.append("u1", event)

    expect(store.since("u1", 0).first.keys)
      .to contain_exactly("id", "topic", "subject", "occurred_at", "data")
  end

  it "round-trips nested data through jsonb unchanged" do
    store.append("u1", event(data: { "nested" => { "k" => [1, 2] }, "s" => "x" }))

    expect(store.since("u1", 0).first["data"]).to eq("nested" => { "k" => [1, 2] }, "s" => "x")
  end

  it "renders occurred_at in the one form the wire publishes" do
    store.append("u1", event)

    expect(store.since("u1", 0).first["occurred_at"]).to eq("2026-09-25T10:00:00Z")
  end

  it "accepts a nil subject" do
    store.append("u1", event(subject: nil))

    expect(store.since("u1", 0).first["subject"]).to be_nil
  end

  it "answers head 0 and an empty tail on a fresh origin" do
    expect(store.head).to eq(0)
    expect(store.since("u1", 0)).to eq([])
  end

  it "keeps identities apart" do
    store.append("u1", event)

    expect(store.since("u2", 0)).to eq([])
  end

  # ── what only a table can do, and the whole reason this is the default ────

  # THE PROPERTY THE DECISION WAS MADE FOR. A second store object stands in for
  # the process that comes back after a deploy — and for the second Puma worker,
  # which the in-process store also cannot serve.
  it "survives the object that wrote the row" do
    store.append("u1", event)

    expect(described_class.new.since("u1", 0).length).to eq(1)
  end

  it "is visible from a DIFFERENT database connection" do
    store.append("u1", event)

    seen = Thread.new { described_class.new.since("u1", 0).length }.value
    expect(seen).to eq(1)
  end

  describe "retention" do
    it "sweeps rows past the window and reports truncated to a stale cursor" do
      store.append("u1", event)
      second = store.append("u1", event)
      backdate(id_below: second, hours: 25)
      store.prune!

      expect(store.truncated?("u1", 0)).to be(true)
      expect(store.truncated?("u1", second)).to be(false)
    end

    it "keeps rows inside the window" do
      store.append("u1", event)
      store.prune!

      expect(store.since("u1", 0).length).to eq(1)
    end

    # An hour was the old floor, reasoned from one access-token lifetime. It is
    # the right bound for a WAIT and the wrong one for a SUBSCRIPTION, which is
    # what `delivery` and `todo` are.
    it "retains for 24 hours by default, not one" do
      expect(described_class::DEFAULT_RETENTION_HOURS).to eq(24)
    end

    it "honours a longer window an operator configures" do
      store.append("u1", event)
      backdate(id_below: store.head + 1, hours: 25)
      described_class.new(retention_hours: 48).prune!

      expect(store.since("u1", 0).length).to eq(1)
    end
  end

  it "is NOT truncated for a cursor at head" do
    id = store.append("u1", event)

    expect(store.truncated?("u1", id)).to be(false)
  end

  it "is NOT truncated on an empty origin" do
    expect(store.truncated?("u1", 0)).to be(false)
  end

  def backdate(id_below:, hours:)
    ::ActiveRecord::Base.connection.exec_query(
      %(UPDATE "#{EVENTS_SPEC_SCHEMA}".events
           SET created_at = now() - ($1 || ' hours')::interval
         WHERE id < $2),
      "spec backdate", [hours.to_s, id_below],
    )
  end
end
