# frozen_string_literal: true

# A query handler returns a Page instead of a bare Array to paginate; the wire
# writes its cursor and total as the `Link` and `X-Total-Count` headers.

RSpec.describe Kiosk::Server::Page do
  it 'carries rows and defaults next_cursor to nil (last page)' do
    page = described_class.new(rows: [{ id: 1 }])
    expect(page.rows).to eq([{ id: 1 }])
    expect(page.next_cursor).to be_nil
  end

  it 'carries the next_cursor it is given' do
    expect(described_class.new(rows: [{ id: 1 }], next_cursor: 'abc').next_cursor).to eq('abc')
  end

  # nil, not rows.length: a handler that does not know the total must produce
  # NO `X-Total-Count` rather than one stating the page size (T-092).
  it 'defaults total to nil — the header is omitted, never guessed' do
    expect(described_class.new(rows: [{ id: 1 }]).total).to be_nil
    expect(described_class.new(rows: [{ id: 1 }], total: 97).total).to eq(97)
  end

  describe Kiosk::Server::Cursor do
    describe '.encode_offset / .decode_offset round-trip' do
      # K-1403: the offset is PUBLISHED, as a decimal integer. The predecessor of
      # this example asserted the opposite — that the encoding hid "40" — which
      # was a claim about a base64 wrapper that hid nothing from anybody.
      it 'publishes the offset as a decimal integer and reads it back' do
        encoded = described_class.encode_offset(40)
        expect(encoded).to eq('40')
        expect(described_class.decode_offset(encoded)).to eq(40)
      end

      it 'decodes a nil/empty cursor to the default (first page)' do
        expect(described_class.decode_offset(nil)).to eq(0)
        expect(described_class.decode_offset('')).to eq(0)
        expect(described_class.decode_offset(nil, default: 5)).to eq(5)
      end

      # The lenience this replaces answered a mangled cursor with page one, so an
      # assistant that corrupted the token got plausible rows and no signal.
      it 'refuses a cursor it did not issue with a typed 400, not a silent page one' do
        ['not-a-cursor', 'b2Zmc2V0OjQw', '-5', '4.0', ' 40', '40 '].each do |bad|
          expect { described_class.decode_offset(bad) }
            .to raise_error(Kiosk::Server::Errors::BadRequest, /is not a cursor this endpoint issued/)
        end
      end

      it 'names the parameter and steers to the Link target in its hint' do
        expect { described_class.decode_offset('nope') }
          .to raise_error(Kiosk::Server::Errors::BadRequest) { |e|
            expect(e.to_problem.fetch(:hint)).to include('rel="next"')
          }
      end
    end
  end
end
