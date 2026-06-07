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

    it "constructs with :stream kind for events" do
      r = described_class.new(kind: :stream, payload: [{ k: "x" }])
      expect(r.kind).to eq(:stream)
    end

    it "coerces kind to a symbol" do
      r = described_class.new(kind: "rows", payload: [])
      expect(r.kind).to eq(:rows)
    end

    it "rejects unknown kind" do
      expect { described_class.new(kind: :unknown, payload: []) }
        .to raise_error(ArgumentError, /kind must be one of/)
    end

    it "carries optional query_id for log correlation" do
      r = described_class.new(kind: :rows, payload: [], query_id: "q-42")
      expect(r.query_id).to eq("q-42")
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

    it "puts :stream payload under `events` key" do
      r = described_class.new(kind: :stream, payload: [{ k: 1 }])
      expect(r.to_envelope).to eq(ok: true, kind: :stream, events: [{ k: 1 }])
    end

    it "includes query_id when set" do
      r = described_class.new(kind: :rows, payload: [], query_id: "q-9")
      expect(r.to_envelope[:query_id]).to eq("q-9")
    end

    it "omits query_id when nil" do
      r = described_class.new(kind: :rows, payload: [])
      expect(r.to_envelope).not_to have_key(:query_id)
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
