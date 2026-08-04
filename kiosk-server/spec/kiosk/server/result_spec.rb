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

  describe "#to_envelope" do
    it "puts :rows payload under `rows` key" do
      r = described_class.new(kind: :rows, payload: [{ a: 1 }])
      expect(r.to_envelope).to eq(ok: true, kind: :rows, rows: [{ a: 1 }])
    end

    it "puts :value payload under `value` key" do
      r = described_class.new(kind: :value, payload: { ok: 1 })
      expect(r.to_envelope).to eq(ok: true, kind: :value, value: { ok: 1 })
    end

    # ── pagination cursor (ADR-0021 / T-042) ──────────────────────────────
    # ABSENT `next` = complete; PRESENT `next` = truncated (more rows exist).

    it "omits `next` entirely when the query did not paginate (back-compat)" do
      r = described_class.new(kind: :rows, payload: [{ a: 1 }])
      expect(r.to_envelope).not_to have_key(:next)
      expect(r.to_envelope).to eq(ok: true, kind: :rows, rows: [{ a: 1 }])
    end

    it "emits `next` (the opaque cursor) when the result was truncated" do
      r = described_class.new(kind: :rows, payload: [{ a: 1 }], next_cursor: "b2Zmc2V0OjQw")
      expect(r.to_envelope).to eq(ok: true, kind: :rows, rows: [{ a: 1 }], next: "b2Zmc2V0OjQw")
    end

    it "a :value result never carries `next` (single-object/action results)" do
      r = described_class.new(kind: :value, payload: { id: 7 })
      expect(r.to_envelope).not_to have_key(:next)
    end
  end

  describe "next_cursor validation" do
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
