# frozen_string_literal: true

# `minitest` (not `minitest/autorun` — no second at_exit runner inside an
# RSpec process): the Minitest half below runs a real Minitest::Test.
require 'minitest'

require 'kiosk/test_helpers'
require 'kiosk/test_helpers/conformance/minitest'
require 'kiosk/test_helpers/conformance/rspec'

# This file drives one broken origin through both adapters, Minitest and
# RSpec, and checks that the operator reads the same sentence from each. The
# Minitest half runs a real `Minitest::Test`; it does not stub `assert`.
# Runs one Minitest test method and catches one RSpec failure.
module ConformanceAdapterRuns
  def verb_class  = Kiosk::TestHelpers::Conformance::Verb
  def null_origin = Kiosk::TestHelpers::Conformance::NullOrigin

  # Runs ONE Minitest test method and returns [passed?, message].
  def run_minitest(&)
    klass = Class.new(Minitest::Test) do
      include Kiosk::TestHelpers::Conformance::Assertions

      define_method(:test_the_one_thing, &)
    end
    result = klass.new(:test_the_one_thing).run
    [result.passed?, result.failures.map(&:message).join("\n")]
  end

  # The failure message of the RSpec expectation in the block, or nil.
  def rspec_failure_message
    yield
    nil
  rescue RSpec::Expectations::ExpectationNotMetError => e
    e.message
  end
end

RSpec.shared_context 'with a lying and an honest origin' do
  include ConformanceAdapterRuns

  # A query whose handler renders a price as a formatted String where its own
  # output_schema declares an integer: a descriptor lie that nothing on the
  # wire would notice.
  let(:lying_verb) do
    verb_class.new(
      name: 'catalog', kind: :query,
      input_schema: { 'type' => 'object', 'additionalProperties' => false, 'properties' => {}, 'required' => [] },
      output_schema: { 'type' => 'array',
                       'items' => { 'type' => 'object',
                                    'properties' => { 'price_cents' => { 'type' => 'integer' } },
                                    'required' => %w[price_cents] } }
    )
  end
  let(:lying_origin)  { null_origin.new(verbs: [lying_verb], answers: { 'catalog' => [{ 'price_cents' => '4.49' }] }) }
  let(:honest_origin) { null_origin.new(verbs: [lying_verb], answers: { 'catalog' => [{ 'price_cents' => 449 }] }) }
end

RSpec.describe 'the conformance adapters', 'Minitest assertions' do
  include_context 'with a lying and an honest origin'

  it 'passes on a conforming origin and COUNTS the assertion' do
    origin = honest_origin
    klass  = Class.new(Minitest::Test) do
      include Kiosk::TestHelpers::Conformance::Assertions

      define_method(:test_shape) do
        assert_kiosk_answer_matches_declared_schema(:catalog, origin: origin)
      end
    end
    result = klass.new(:test_shape).run

    expect(result.passed?).to be(true)
    # A green run that made no assertions is how a suite stops running
    # without anybody noticing.
    expect(result.assertions).to eq(1)
  end

  it 'fails on the descriptor lie' do
    origin = lying_origin
    passed, message = run_minitest { assert_kiosk_answer_matches_declared_schema(:catalog, origin: origin) }

    expect(passed).to be(false)
    expect(message).to include('rendered a payload its own output_schema rejects')
  end
end

RSpec.describe 'the conformance adapters', 'Minitest assertions, all checks' do
  include_context 'with a lying and an honest origin'

  it 'reaches all four checks' do
    origin = honest_origin
    passed, message = run_minitest do
      assert_kiosk_verbs_routed(origin: origin)
      assert_kiosk_verb_executes(:catalog, origin: origin)
      assert_kiosk_answer_matches_declared_schema(:catalog, origin: origin)
      assert_kiosk_scoped_to_principal(:catalog, as: :alice, and_not: :bob, origin: origin)
    end

    # The fourth one FAILS here on purpose and for the right reason: this
    # fixture answers both principals the same rows, which is the vacuity the
    # scoping check refuses to pass.
    expect(passed).to be(false)
    expect(message).to include('leaked')
  end

  it 'honours an explicit message' do
    origin = lying_origin
    _, message = run_minitest do
      assert_kiosk_answer_matches_declared_schema(:catalog, origin: origin, message: 'catalog lies')
    end

    expect(message).to include('catalog lies')
  end

  it 'reports the wiring hint when no origin is configured' do
    # Minitest turns an exception inside a test method into a recorded
    # error, so the hint reaches the operator through the run result rather
    # than by propagating out of it.
    passed, message = run_minitest { assert_kiosk_verbs_routed }

    expect(passed).to be(false)
    expect(message).to include('has no origin configured')
    expect(message).to include('ConformanceOrigin')
  end
end

RSpec.describe 'the conformance adapters', 'RSpec matchers' do
  include_context 'with a lying and an honest origin'

  before { Kiosk::TestHelpers::Conformance.origin = honest_origin }

  it 'passes on a conforming origin' do
    expect(kiosk_origin).to have_a_route_for_every_verb
    expect(:catalog).to execute_as_a_kiosk_verb
    expect(:catalog).to answer_its_declared_schema
  end

  it 'falls back to the configured origin when handed nil' do
    expect(nil).to have_a_route_for_every_verb
  end
end

RSpec.describe 'the conformance adapters', 'RSpec matchers given an origin:' do
  include_context 'with a lying and an honest origin'

  before { Kiosk::TestHelpers::Conformance.origin = honest_origin }

  # The matcher must answer about the `origin:` it is given, not the
  # configured one: an adopter can have more than one origin.
  it 'honours an explicit origin: over a broken configured one' do
    broken = null_origin.new(verbs: [lying_verb], routes: {})
    Kiosk::TestHelpers::Conformance.origin = broken

    # CONTROL ONE: the configured origin really is unrouted, so a green
    # keyword example below cannot be green for want of anything to catch.
    expect { expect(nil).to have_a_route_for_every_verb }
      .to raise_error(RSpec::Expectations::ExpectationNotMetError, /not routed as their kind requires/)

    # CONTROL TWO: the configured-origin path still works — the subject form
    # names its own origin and is unaffected by the keyword.
    expect(honest_origin).to have_a_route_for_every_verb

    # THE PROPERTY: the keyword is honoured, not dropped.
    expect(nil).to have_a_route_for_every_verb(origin: honest_origin)
  end

  it 'honours origin: on all four matchers, the parity the header claims' do
    Kiosk::TestHelpers::Conformance.origin = null_origin.new(verbs: [lying_verb], routes: {})
    scoped = null_origin.new(
      verbs: [lying_verb],
      answers: { ['catalog', :alice] => [{ 'price_cents' => 1 }],
                 ['catalog', :bob] => [{ 'price_cents' => 2 }] }
    )

    expect(nil).to have_a_route_for_every_verb(origin: honest_origin)
    expect(:catalog).to execute_as_a_kiosk_verb(origin: honest_origin)
    expect(:catalog).to answer_its_declared_schema(origin: honest_origin)
    expect(:catalog).to be_scoped_to_principal(as: :alice, and_not: :bob, origin: scoped)
  end
end

RSpec.describe 'the conformance adapters', 'RSpec matchers on a configured origin' do
  include_context 'with a lying and an honest origin'

  before { Kiosk::TestHelpers::Conformance.origin = honest_origin }

  it 'fails on the descriptor lie' do
    Kiosk::TestHelpers::Conformance.origin = lying_origin

    expect { expect(:catalog).to answer_its_declared_schema }
      .to raise_error(RSpec::Expectations::ExpectationNotMetError,
                      /rendered a payload its own output_schema rejects/)
  end

  it 'forwards params: and as: to the check' do
    expect(:catalog).to execute_as_a_kiosk_verb(params: { 'q' => 1 }, as: :alice)

    expect(honest_origin.calls.last).to include(params: { 'q' => 1 }, as: :alice)
  end

  it 'runs the scoping matcher with both principals' do
    origin = null_origin.new(
      verbs: [lying_verb],
      answers: { %w[catalog].first => nil,
                 ['catalog', :alice] => [{ 'price_cents' => 1 }],
                 ['catalog', :bob] => [{ 'price_cents' => 2 }] }
    )
    Kiosk::TestHelpers::Conformance.origin = origin

    expect(:catalog).to be_scoped_to_principal(as: :alice, and_not: :bob)
  end
end

RSpec.describe 'the conformance adapters', 'the two adapters report the SAME sentence' do
  include_context 'with a lying and an honest origin'

  it 'for a descriptor lie' do
    origin = lying_origin
    _, minitest_message = run_minitest do
      assert_kiosk_answer_matches_declared_schema(:catalog, origin: origin)
    end

    Kiosk::TestHelpers::Conformance.origin = lying_origin
    rspec_message = rspec_failure_message { expect(:catalog).to answer_its_declared_schema }

    core_message = Kiosk::TestHelpers::Conformance::Checks
                   .declared_shape(lying_origin, :catalog).message

    expect(minitest_message).to include(core_message)
    expect(rspec_message).to include(core_message)
  end

  it 'for a verb that is not declared at all' do
    origin = honest_origin
    _, minitest_message = run_minitest { assert_kiosk_verb_executes(:catalogue, origin: origin) }

    Kiosk::TestHelpers::Conformance.origin = honest_origin
    rspec_message = rspec_failure_message { expect(:catalogue).to execute_as_a_kiosk_verb }

    expect(minitest_message).to include('no verb named "catalogue"')
    expect(rspec_message).to include('no verb named "catalogue"')
  end
end
