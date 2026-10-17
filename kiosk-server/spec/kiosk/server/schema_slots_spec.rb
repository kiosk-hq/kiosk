# frozen_string_literal: true

# DATA-DERIVED DESCRIPTOR SLOTS.
#
# A descriptor slot may be a proc — `enum: -> { Category.pluck(:slug) }` — so a
# schema can state a fact about the operator's ROWS. Three properties hold:
#
#   1. NOTHING IS CALLED AT CLASS-BODY LOAD. `db:create`, `db:migrate` and
#      `assets:precompile` read the class body with no table to read from.
#   2. IT IS MEMOIZED, BUT NOT FOREVER. `describe` is on the per-request
#      validation path, so an unmemoized proc is a query per verb call; a memo
#      with no lifetime needs a restart per new category.
#   3. THE FILL IS SYNCHRONISED. Puma is multi-threaded. Two threads filling
#      an empty memo must run the proc ONCE and must not publish two different
#      answers inside one window.
module SchemaSlotsSpec
  def declare_board(enum)
    declare_query('board', input_schema: { type: 'object', properties: { category: { enum: enum } } })
  end

  def board_enum
    Kiosk::Server::Queries.describe('board')[:input_schema][:properties][:category][:enum]
  end

  # Releases `count` threads at once into `read` and returns their answers.
  def race(count, &read)
    released = Queue.new
    threads = Array.new(count) do
      Thread.new do
        released.pop
        read.call
      end
    end
    count.times { released << :go }
    threads.map(&:value)
  end
end

RSpec.shared_context 'schema slots spec: issuer' do
  include SchemaSlotsSpec

  before { Kiosk.configure { |c| c.issuer = 'https://demo.example' } }
end

RSpec.describe Kiosk::Server::SchemaSlots do
  include_context 'schema slots spec: issuer'

  describe 'declaration time' do
    it 'does NOT call a proc slot while the class body is read' do
      called = false
      recording = lambda do
        called = true
        %w[a]
      end

      expect { declare_board(recording) }.not_to raise_error

      expect(called).to be(false)
    end

    # A class body is read by `db:create`, long before any table exists. A
    # proc that raises there must not stop the declaration from registering.
    it 'registers a verb whose proc would RAISE if it were called now' do
      declare_board(-> { raise 'no database yet' })

      expect(Kiosk::Server::Queries.known).to include('board')
    end

    it 'leaves an origin with no proc anywhere entirely alone' do
      declare_query('menu')

      expect(described_class.dynamic_declarations?).to be(false)
      expect(described_class.epoch).to eq(0)
    end
  end
end

RSpec.describe Kiosk::Server::SchemaSlots do
  include_context 'schema slots spec: issuer'

  describe '.descriptor resolution' do
    it 'resolves an `enum` proc when the descriptor is READ, not when it is declared' do
      declare_query('board', input_schema: {
                      type: 'object',
                      properties: { category: { type: 'string', enum: -> { %w[bikes free] } } }
                    })

      descriptor = Kiosk::Server::Queries.describe('board')

      expect(descriptor[:input_schema][:properties][:category][:enum]).to eq(%w[bikes free])
    end

    # `enum` is not special — the slot list is the four STRUCTURAL slots, so a
    # `maximum` read from a configured cap or an `example_row` built from a
    # real row works the same way.
    it 'resolves a proc in output_schema, example_params and example_row too' do
      declare_action('post', input_schema: { type: 'object' },
                             output_schema: { type: 'object', properties: { n: { maximum: -> { 7 } } } },
                             example_params: { category: -> { 'bikes' } },
                             example_row: { id: -> { 'row-1' } })

      descriptor = Kiosk::Server::Actions.describe('post')

      expect(descriptor[:output_schema][:properties][:n][:maximum]).to eq(7)
      expect(descriptor[:example_params][:category]).to eq('bikes')
      expect(descriptor[:example_row][:id]).to eq('row-1')
    end

    it 'reaches the catalog, and therefore the served document' do
      declare_board(-> { %w[bikes] })

      expect(Kiosk::Server::SchemaDocument.json).to include('"enum":["bikes"]')
    end
  end
end

RSpec.describe Kiosk::Server::SchemaSlots do
  include_context 'schema slots spec: issuer'

  describe 'the memo, and its lifetime' do
    it 'calls the proc ONCE across many reads inside one window' do
      calls = 0
      described_class.refresh_seconds = 3600
      declare_board(lambda do
        calls += 1
        %w[bikes]
      end)

      10.times { Kiosk::Server::Queries.describe('board') }

      expect(calls).to eq(1)
    end

    # A memo with no expiry means an operator who adds a category has to
    # restart the process to publish it.
    it 're-resolves after the window, with no reset, no reload and no restart' do
      slugs = %w[bikes]
      described_class.refresh_seconds = 0
      declare_board(-> { slugs })

      expect(board_enum).to eq(%w[bikes])

      slugs = %w[bikes free] # the operator adds a category

      expect(board_enum).to eq(%w[bikes free])
    end
  end
end

RSpec.describe Kiosk::Server::SchemaSlots do
  include_context 'schema slots spec: issuer'

  describe 'the memo, and its lifetime' do
    it 'holds the previous value for the rest of the window' do
      slugs = %w[bikes]
      described_class.refresh_seconds = 3600
      declare_board(-> { slugs })

      Kiosk::Server::Queries.describe('board')
      slugs = %w[bikes free]

      expect(board_enum).to eq(%w[bikes])
    end

    # A code reload replaces the registry Entry. The memo is keyed on that
    # object's IDENTITY, so it invalidates without anyone remembering to.
    it 'invalidates when the verb is re-declared' do
      described_class.refresh_seconds = 3600
      declare_board(-> { %w[bikes] })
      Kiosk::Server::Queries.describe('board')

      declare_board(-> { %w[housing] })

      expect(board_enum).to eq(%w[housing])
    end
  end
end

RSpec.describe Kiosk::Server::SchemaSlots do
  include_context 'schema slots spec: issuer'

  describe 'SPEC-278: reuse bound and caller independence' do
    it "reuses a derived value no longer than the discovery document's freshness lifetime" do
      described_class.refresh_seconds = nil
      expect(described_class.refresh_seconds).to be <= Kiosk::Server::Headers::SHORT_MAX_AGE
    end

    it 'answers every caller with one descriptor, resolved once' do
      described_class.refresh_seconds = 3600
      calls = 0
      declare_board(lambda do
        calls += 1
        %w[bikes]
      end)

      seen = %w[u-1 u-2].map do |user_id|
        Kiosk::Server::CurrentRequest.with(identity: build_identity(user_id: user_id)) do
          Kiosk::Server::Queries.describe('board')
        end
      end

      expect(seen.uniq.size).to eq(1)
      expect(calls).to eq(1)
    end
  end
end

# Puma is multi-threaded, so concurrent first reads of one descriptor are an
# ordinary event. The barrier releases every thread into the empty memo at
# once and the proc is SLOW, so an unlocked `@cache[key] ||= resolve` runs it
# once per thread and publishes as many different answers.
RSpec.describe Kiosk::Server::SchemaSlots do
  include_context 'schema slots spec: issuer'

  describe 'concurrent first fill' do
    let(:thread_count) { 8 }

    it 'calls the proc exactly once and hands every thread the SAME value' do
      described_class.refresh_seconds = 3600
      calls = 0
      lock  = Mutex.new
      declare_board(lambda do
        nth = lock.synchronize { calls += 1 }
        sleep 0.05 # widen the window an unlocked memo loses
        ["slug-#{nth}"]
      end)

      answers = race(thread_count) { board_enum }

      expect(calls).to eq(1)
      expect(answers.uniq.length).to eq(1)
      expect(answers.first).to eq(%w[slug-1])
    end
  end
end

RSpec.describe Kiosk::Server::SchemaSlots do
  include_context 'schema slots spec: issuer'

  describe 'concurrent first fill' do
    let(:thread_count) { 8 }

    it 'hands every thread the SAME frozen object, so nobody can tear it' do
      described_class.refresh_seconds = 3600
      declare_board(lambda do
        sleep 0.05
        %w[bikes]
      end)

      descriptors = race(thread_count) { Kiosk::Server::Queries.describe('board') }

      expect(descriptors.map(&:object_id).uniq.length).to eq(1)
      expect(descriptors.first).to be_frozen
    end
  end
end

RSpec.describe Kiosk::Server::SchemaSlots do
  include_context 'schema slots spec: issuer'

  describe '.resolve' do
    it 'refuses a proc chain deeper than MAX_DEPTH rather than looping' do
      looping = nil
      looping = -> { looping }

      expect { described_class.resolve(looping) }
        .to raise_error(ArgumentError, /nests procs more than/)
    end

    it 'returns a literal container unchanged rather than copying it' do
      literal = { type: 'string', enum: %w[a b] }

      expect(described_class.resolve(literal)).to equal(literal)
    end
  end
end
