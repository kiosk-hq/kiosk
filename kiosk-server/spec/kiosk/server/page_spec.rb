# frozen_string_literal: true

# Pagination seam a query handler uses to opt into cursor pagination
# (ADR-0021 / T-042). A handler returns a Page (rows + opaque next_cursor)
# instead of a bare Array; the Executor threads next_cursor into the envelope.

RSpec.describe Kiosk::Server::Page do
  it "carries rows and defaults next_cursor to nil (last page)" do
    page = described_class.new(rows: [{ id: 1 }])
    expect(page.rows).to eq([{ id: 1 }])
    expect(page.next_cursor).to be_nil
    expect(page.truncated?).to be(false)
  end

  it "is truncated? when a next_cursor is present" do
    page = described_class.new(rows: [{ id: 1 }], next_cursor: "abc")
    expect(page.next_cursor).to eq("abc")
    expect(page.truncated?).to be(true)
  end
end

RSpec.describe Kiosk::Server::Cursor do
  describe ".encode_offset / .decode_offset round-trip" do
    it "encodes an offset to an opaque base64 string and decodes it back" do
      encoded = described_class.encode_offset(40)
      expect(encoded).to be_a(String)
      # opaque: the client must not be able to read "40" off the wire
      expect(encoded).not_to include("40")
      expect(described_class.decode_offset(encoded)).to eq(40)
    end

    it "decodes a nil/empty cursor to the default (first page)" do
      expect(described_class.decode_offset(nil)).to eq(0)
      expect(described_class.decode_offset("")).to eq(0)
      expect(described_class.decode_offset(nil, default: 5)).to eq(5)
    end

    it "decodes a malformed cursor to the default rather than raising" do
      expect(described_class.decode_offset("not-base64-!!!")).to eq(0)
      expect(described_class.decode_offset(Base64.urlsafe_encode64("garbage"))).to eq(0)
    end
  end
end
