# frozen_string_literal: true

# DATA-DERIVED DESCRIPTOR SLOTS (K-922, Phil 2026-08-21).
#
# A descriptor slot may be a proc — `enum: -> { Category.pluck(:slug) }` — so a
# schema can state a fact about the operator's ROWS. Three properties carry the
# whole decision, and each of them is a way the obvious implementation fails:
#
#   1. NOTHING IS CALLED AT CLASS-BODY LOAD. `db:create`, `db:migrate` and
#      `assets:precompile` read the class body with no table to read from.
#   2. IT IS MEMOIZED, BUT NOT FOREVER. `describe` is on the per-request
#      validation path, so an unmemoized proc is a query per verb call; a memo
#      with no lifetime is a restart per category, which is the deploy
#      dependency the decision exists to remove.
#   3. THE FILL IS SYNCHRONISED. Puma is multi-threaded. Two threads filling
#      an empty memo must run the proc ONCE and must not publish two different
#      answers inside one window.

RSpec.describe Kiosk::Server::SchemaSlots do
  before { Kiosk.configure { |c| c.issuer = "https://demo.example" } }

  describe "declaration time" do
    it "does NOT call a proc slot while the class body is read" do
      called = false

      expect {
        declare_query("board", input_schema: {
                        type: "object",
                        properties: { category: { enum: -> { called = true; %w[a] } } },
                      })
      }.not_to raise_error

      expect(called).to be(false)
    end

    # The failure this is really about: a class body is read by `db:create`,
    # long before any table exists. A proc that raises there must not stop the
    # declaration from registering.
    it "registers a verb whose proc would RAISE if it were called now" do
      declare_query("board", input_schema: {
                      type: "object",
                      properties: { category: { enum: -> { raise "no database yet" } } },
                    })

      expect(Kiosk::Server::Queries.known).to include("board")
    end

    it "leaves an origin with no proc anywhere entirely alone" do
      declare_query("menu")

      expect(described_class.dynamic_declarations?).to be(false)
      expect(described_class.epoch).to eq(0)
    end
  end

  describe ".descriptor resolution" do
    it "resolves an `enum` proc when the descriptor is READ, not when it is declared" do
      declare_query("board", input_schema: {
                      type: "object",
                      properties: { category: { type: "string", enum: -> { %w[bikes free] } } },
                    })

      descriptor = Kiosk::Server::Queries.describe("board")

      expect(descriptor[:input_schema][:properties][:category][:enum]).to eq(%w[bikes free])
    end

    # `enum` is not special — the slot list is the four STRUCTURAL slots, so a
    # `maximum` read from a configured cap or an `example_row` built from a
    # real row works the same way. Restricting it to `enum` would have been an
    # arbitrary carve-out.
    it "resolves a proc in output_schema, example_params and example_row too" do
      declare_action("post", input_schema: { type: "object" },
                             output_schema: { type: "object", properties: { n: { maximum: -> { 7 } } } },
                             example_params: { category: -> { "bikes" } },
                             example_row: { id: -> { "row-1" } })

      descriptor = Kiosk::Server::Actions.describe("post")

      expect(descriptor[:output_schema][:properties][:n][:maximum]).to eq(7)
      expect(descriptor[:example_params][:category]).to eq("bikes")
      expect(descriptor[:example_row][:id]).to eq("row-1")
    end

    it "reaches the catalog, and therefore the served document" do
      declare_query("board", input_schema: {
                      type: "object",
                      properties: { category: { enum: -> { %w[bikes] } } },
                    })

      expect(Kiosk::Server::SchemaDocument.json).to include('"enum":["bikes"]')
    end
  end

  describe "the memo, and its lifetime" do
    it "calls the proc ONCE across many reads inside one window" do
      calls = 0
      described_class.refresh_seconds = 3600
      declare_query("board", input_schema: {
                      type: "object", properties: { category: { enum: -> { calls += 1; %w[bikes] } } },
                    })

      10.times { Kiosk::Server::Queries.describe("board") }

      expect(calls).to eq(1)
    end

    # THE HALF THAT IS NOT "cache on first call": a memo with no expiry means
    # an operator who adds a category has to restart the process to publish
    # it, which is exactly the deploy dependency this decision removes.
    it "re-resolves after the window, with no reset, no reload and no restart" do
      slugs = %w[bikes]
      described_class.refresh_seconds = 0
      declare_query("board", input_schema: {
                      type: "object", properties: { category: { enum: -> { slugs } } },
                    })

      expect(Kiosk::Server::Queries.describe("board")[:input_schema][:properties][:category][:enum])
        .to eq(%w[bikes])

      slugs = %w[bikes free] # the operator adds a category

      expect(Kiosk::Server::Queries.describe("board")[:input_schema][:properties][:category][:enum])
        .to eq(%w[bikes free])
    end

    it "holds the previous value for the rest of the window" do
      slugs = %w[bikes]
      described_class.refresh_seconds = 3600
      declare_query("board", input_schema: {
                      type: "object", properties: { category: { enum: -> { slugs } } },
                    })

      Kiosk::Server::Queries.describe("board")
      slugs = %w[bikes free]

      expect(Kiosk::Server::Queries.describe("board")[:input_schema][:properties][:category][:enum])
        .to eq(%w[bikes])
    end

    # A code reload replaces the registry Entry. The memo is keyed on that
    # object's IDENTITY, so it invalidates without anyone remembering to.
    it "invalidates when the verb is re-declared" do
      described_class.refresh_seconds = 3600
      declare_query("board", input_schema: {
                      type: "object", properties: { category: { enum: -> { %w[bikes] } } },
                    })
      Kiosk::Server::Queries.describe("board")

      declare_query("board", input_schema: {
                     type: "object", properties: { category: { enum: -> { %w[housing] } } },
                   })

      expect(Kiosk::Server::Queries.describe("board")[:input_schema][:properties][:category][:enum])
        .to eq(%w[housing])
    end
  end

  # ── THE RACE (Phil: «Стоит обратить внимание на возможный race condition») ──
  #
  # The shipped demos run WEB_CONCURRENCY=1, but Puma is multi-threaded, so
  # concurrent first reads of one descriptor are an ordinary event. This block
  # is the one that fails against an unsynchronised `@cache[key] ||= resolve`:
  # the barrier releases every thread into the empty memo at once and the proc
  # is deliberately SLOW, so an unlocked implementation runs it once per
  # thread and publishes as many different answers.
  describe "concurrent first fill" do
    let(:thread_count) { 8 }

    it "calls the proc exactly once and hands every thread the SAME value" do
      described_class.refresh_seconds = 3600
      calls    = 0
      lock     = Mutex.new
      released = Queue.new

      declare_query("board", input_schema: {
                      type: "object",
                      properties: {
                        category: {
                          enum: lambda {
                            nth = lock.synchronize { calls += 1 }
                            sleep 0.05 # widen the window an unlocked memo loses
                            ["slug-#{nth}"]
                          },
                        },
                      },
                    })

      threads = Array.new(thread_count) do
        Thread.new do
          released.pop # all threads wait here
          Kiosk::Server::Queries.describe("board")[:input_schema][:properties][:category][:enum]
        end
      end
      thread_count.times { released << :go }
      answers = threads.map(&:value)

      expect(calls).to eq(1)
      expect(answers.uniq.length).to eq(1)
      expect(answers.first).to eq(%w[slug-1])
    end

    it "hands every thread the SAME frozen object, so nobody can tear it" do
      described_class.refresh_seconds = 3600
      released = Queue.new
      declare_query("board", input_schema: {
                      type: "object",
                      properties: { category: { enum: -> { sleep 0.05; %w[bikes] } } },
                    })

      threads = Array.new(thread_count) do
        Thread.new { released.pop; Kiosk::Server::Queries.describe("board") }
      end
      thread_count.times { released << :go }
      descriptors = threads.map(&:value)

      expect(descriptors.map(&:object_id).uniq.length).to eq(1)
      expect(descriptors.first).to be_frozen
    end
  end

  describe ".resolve" do
    it "refuses a proc chain deeper than MAX_DEPTH rather than looping" do
      looping = nil
      looping = -> { looping }

      expect { described_class.resolve(looping) }
        .to raise_error(ArgumentError, /nests procs more than/)
    end

    it "returns a literal container unchanged rather than copying it" do
      literal = { type: "string", enum: %w[a b] }

      expect(described_class.resolve(literal)).to equal(literal)
    end
  end
end
