# frozen_string_literal: true

RSpec.describe Kiosk::Server::Result do
  describe ".new" do
    it "constructs with :rows kind and an Array payload" do
      r = described_class.new(kind: :rows, payload: [{ a: 1 }])
      expect(r.kind).to    eq(:rows)
      expect(r.payload).to eq([{ a: 1 }])
    end

    it "constructs with :value kind for Action results" do
      r = described_class.new(kind: :value, payload: { id: 7 })
      expect(r.kind).to    eq(:value)
      expect(r.payload).to eq({ id: 7 })
    end

    # The :stream kind (events verb) was removed — it is now rejected
    # like any other unknown kind.
    it "rejects the removed :stream kind" do
      expect { described_class.new(kind: :stream, payload: []) }
        .to raise_error(ArgumentError, /kind must be one of/)
    end

    it "coerces kind to a symbol" do
      r = described_class.new(kind: "rows", payload: [])
      expect(r.kind).to eq(:rows)
    end

    it "rejects unknown kind" do
      expect { described_class.new(kind: :unknown, payload: []) }
        .to raise_error(ArgumentError, /kind must be one of/)
    end
  end

  describe "#ok? and #http_status" do
    it "always reports ok and HTTP 200" do
      r = described_class.new(kind: :rows, payload: [])
      expect(r.ok?).to         be(true)
      expect(r.http_status).to eq(200)
    end
  end

  # THE ENVELOPE IS GONE (T-074 = A). `to_envelope` was the 0.3 success
  # wrapper — `{ok:, kind:, rows|value:, next:}` — and it was deleted with the
  # two endpoints that served it. Pinned here because a re-added wrapper would
  # otherwise be invisible: nothing else in the suite would notice a second
  # answer shape appearing beside {#to_payload}.
  it "has no 0.3 envelope left to render" do
    r = described_class.new(kind: :rows, payload: [{ a: 1 }])
    expect(r).not_to respond_to(:to_envelope)
  end

  # THE 0.4 SUCCESS BODY (T-072 = C). Whatever the handler rendered is what
  # the wire carries — and since T-092 there is no composite shape left at all:
  # a paginating query answers the same bare array as any other, with its two
  # page facts on the `Link` and `X-Total-Count` response headers.
  describe "#to_payload" do
    it "is the handler's rows, bare, when nothing paginated" do
      expect(described_class.new(kind: :rows, payload: [{ a: 1 }]).to_payload).to eq([{ a: 1 }])
    end

    it "is STILL the bare rows when the query paginated — the cursor is a header now" do
      r = described_class.new(kind: :rows, payload: [{ a: 1 }],
                              next_cursor: "b2Zmc2V0OjQw", total: 97)
      expect(r.to_payload).to eq([{ a: 1 }])
      expect(r.next_cursor).to eq("b2Zmc2V0OjQw")
      expect(r.total).to eq(97)
    end

    # The shape that is GONE, pinned so a re-added body wrapper cannot slip
    # back in unnoticed (RFC 8288 adoption, T-092).
    it "never renders a {rows, next} object" do
      r = described_class.new(kind: :rows, payload: [{ a: 1 }], next_cursor: "c")
      expect(r.to_payload).not_to be_a(Hash)
    end

    it "is the action's own object, bare" do
      expect(described_class.new(kind: :value, payload: { id: 7 }).to_payload).to eq(id: 7)
    end

    it "carries no `ok` and no `kind` — the status line and output_schema do that" do
      payload = described_class.new(kind: :value, payload: { id: 7 }).to_payload
      expect(payload).not_to have_key(:ok)
      expect(payload).not_to have_key(:kind)
    end
  end

  describe "next_cursor validation" do
    it "rejects a total on a non-:rows result" do
      expect { described_class.new(kind: :value, payload: {}, total: 3) }
        .to raise_error(ArgumentError, /only valid on a :rows result/)
    end

    it "rejects a next_cursor on a non-:rows result" do
      expect { described_class.new(kind: :value, payload: {}, next_cursor: "x") }
        .to raise_error(ArgumentError, /only valid on a :rows result/)
    end

    it "defaults next_cursor to nil (unpaginated)" do
      expect(described_class.new(kind: :rows, payload: []).next_cursor).to be_nil
    end
  end

  describe "value equality" do
    it "Data class equality by fields" do
      a = described_class.new(kind: :rows, payload: [{ x: 1 }])
      b = described_class.new(kind: :rows, payload: [{ x: 1 }])
      expect(a).to eq(b)
    end
  end
end
