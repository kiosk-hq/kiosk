# frozen_string_literal: true

# The read-side registry. A verb gets into it one way: a controller that
# includes Kiosk::Handler and declares `kind :query`. `declare_query`
# (spec_helper) builds exactly that. These examples cover the registry's own
# surface: fetch, describe, catalog, known, reset!.
RSpec.describe Kiosk::Server::Queries do
  describe '.fetch' do
    it 'returns the registered handler' do
      declare_query('menu')

      expect(described_class.fetch('menu')).to be_a(Kiosk::Server::HandlerDispatch)
    end

    it 'accepts a symbol name (registry keys are strings)' do
      declare_query('menu')

      expect(described_class.fetch(:menu)).to eq(described_class.fetch('menu'))
    end
  end
end

RSpec.describe Kiosk::Server::Queries do
  describe '.fetch unknown name' do
    it 'raises NotFound whose hint names the available queries and points at the schema' do
      declare_query('browse_listings')
      declare_query('listing_detail')

      expect { described_class.fetch('listings') }
        .to raise_error(Kiosk::Server::Errors::VerbNotFound) { |e|
          expect(e.message).to include('listings')
          # The hint names the available queries, so a near-miss typo is
          # recoverable without the schema, and it still points at the schema.
          expect(e.hint).to include('browse_listings', 'listing_detail', "unknown query 'listings'")
          expect(e.hint).to match(/schema/)
        }
    end

    it 'caps a very long hint list at 20 names + an ellipsis, still pointing at the schema' do
      30.times { |i| declare_query(format('q%02d', i)) }

      expect { described_class.fetch('nope') }
        .to raise_error(Kiosk::Server::Errors::VerbNotFound) { |e|
          expect(e.hint).to include('q00', 'q19', '…')
          expect(e.hint).not_to include('q20') # capped
          expect(e.hint).to match(/schema/)
        }
    end
  end
end

RSpec.describe Kiosk::Server::Queries do
  describe '.known' do
    it 'lists registered query names' do
      declare_query('a')
      declare_query('b')
      expect(described_class.known).to contain_exactly('a', 'b')
    end

    it 'is empty after reset!' do
      declare_query('a')
      described_class.reset!
      expect(described_class.known).to be_empty
    end
  end
end

RSpec.describe Kiosk::Server::Queries do
  describe '.describe' do
    it 'carries the declared description into the descriptor' do
      declare_query('menu', description: 'Browse the menu')

      descriptor = described_class.describe('menu')
      expect(descriptor[:name]).to        eq('menu')
      expect(descriptor[:description]).to eq('Browse the menu')
    end

    # A descriptor MUST NOT publish `params`. The example asserts that the key
    # is absent, because a nil value would pass for a key published as null.
    it 'does not publish params at all — the slot left the wire (T-085)' do
      declare_query('menu', description: 'Browse the menu')

      expect(described_class.describe('menu')).not_to have_key(:params)
    end
  end
end

RSpec.describe Kiosk::Server::Queries do
  describe '.describe' do
    it 'leaves description nil when the verb opted in with another macro' do
      declare_query('bare', input_schema: { type: 'object' })

      descriptor = described_class.describe('bare')
      expect(descriptor[:description]).to be_nil
      expect(descriptor).not_to have_key(:params)
    end

    it 'fetch returns the handler, not the Entry' do
      declare_query('items', description: 'List items') { render json: [{ id: 1 }] }

      fetched = described_class.fetch('items')
      expect(fetched).not_to be_a(described_class::Entry)
      expect(fetched).to respond_to(:call)
    end
  end
end

RSpec.describe Kiosk::Server::Queries do
  describe '.catalog' do
    it 'returns all descriptors sorted by name' do
      declare_query('zebra', description: 'Last')
      declare_query('apple', description: 'First')

      cat = described_class.catalog
      expect(cat.map { |d| d[:name] }).to eq(%w[apple zebra])
      expect(cat.first[:description]).to  eq('First')
      expect(cat.last[:description]).to   eq('Last')
    end

    it 'is empty after reset!' do
      declare_query('a')
      described_class.reset!
      expect(described_class.catalog).to be_empty
    end

    it 'leaves known returning names only' do
      declare_query('x', description: 'Something')
      expect(described_class.known).to eq(['x'])
    end
  end
end

RSpec.describe Kiosk::Server::Queries do
  describe 'machine-readable descriptor extensions (input_schema / example_params / example_row — ADR-0021)' do
    let(:input_schema) do
      { type: 'object', required: ['city'],
        properties: { city: { type: 'string' }, limit: { type: 'integer', minimum: 1, maximum: 50 } } }
    end

    it 'carries the declared schemas and examples into the descriptor' do
      declare_query('search',
                    description: 'Search hotels',
                    input_schema: input_schema,
                    example_params: { city: 'Lisbon', limit: 20 },
                    example_row: { id: 7, name: 'Grand Aljube', city: 'Lisbon' })

      d = described_class.describe('search')
      expect(d[:input_schema]).to   eq(input_schema)
      expect(d[:example_params]).to eq({ city: 'Lisbon', limit: 20 })
      expect(d[:example_row]).to    eq({ id: 7, name: 'Grand Aljube', city: 'Lisbon' })
    end
  end
end

# An extension a descriptor does not declare is absent, never null. These
# examples call `declare` directly: the handler mixin requires both schemas on
# every verb, while the registry itself still takes nil for each optional field.
RSpec.describe Kiosk::Server::Queries do
  describe 'machine-readable descriptor extensions (input_schema / example_params / example_row — ADR-0021)' do
    it 'OMITS the extension keys entirely when they are not declared' do
      described_class.declare('plain', ->(_args) { [] }, description: 'Browse')

      d = described_class.describe('plain')
      expect(d).to eq({ name: 'plain', description: 'Browse', reach: 'principal' })
      expect(d.keys).not_to include(:input_schema, :output_schema, :example_params, :example_row)
    end

    it 'emits only the extension keys that were declared' do
      described_class.declare('partial', ->(_args) { [] }, example_params: { city: 'Porto' })

      d = described_class.describe('partial')
      expect(d).to have_key(:example_params)
      expect(d).not_to have_key(:input_schema)
      expect(d).not_to have_key(:example_row)
    end
  end
end
