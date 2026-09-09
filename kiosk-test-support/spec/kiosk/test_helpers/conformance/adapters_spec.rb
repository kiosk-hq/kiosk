# frozen_string_literal: true

# `minitest` (not `minitest/autorun` — no second at_exit runner inside an
# RSpec process): the Minitest half below runs a real Minitest::Test.
require "minitest"

require "kiosk/test_helpers"
require "kiosk/test_helpers/conformance/minitest"
require "kiosk/test_helpers/conformance/rspec"

# THE FRAMEWORK-AGNOSTIC CLAIM, EXECUTED.
#
# "Serves both Minitest and RSpec" is worth exactly nothing unless something
# runs both, so this file drives ONE broken origin through BOTH adapters and
# asserts that the sentence an operator reads is the same sentence. That is what
# the claim has to cash out as: a fault found in one framework and reproduced in
# the other must not require a translation step.
#
# The Minitest half is driven by instantiating a real `Minitest::Test` and
# running it — not by stubbing `assert`. A test double would prove that this
# file calls the adapter, which is not the question.
RSpec.describe "the conformance adapters" do
  def verb_class  = Kiosk::TestHelpers::Conformance::Verb
  def null_origin = Kiosk::TestHelpers::Conformance::NullOrigin

  # A query whose handler renders a price as a formatted String where its own
  # output_schema declares an integer — a descriptor lie nothing on the wire
  # would notice, and the shape check's reason for existing.
  let(:lying_verb) do
    verb_class.new(
      name: "catalog", kind: :query,
      input_schema:  { "type" => "object", "additionalProperties" => false,
                       "properties" => {}, "required" => [] },
      output_schema: { "type" => "array",
                       "items" => { "type" => "object",
                                    "properties" => { "price_cents" => { "type" => "integer" } },
                                    "required" => %w[price_cents] } },
    )
  end

  let(:lying_origin) do
    null_origin.new(verbs: [lying_verb], answers: { "catalog" => [{ "price_cents" => "4.49" }] })
  end

  let(:honest_origin) do
    null_origin.new(verbs: [lying_verb], answers: { "catalog" => [{ "price_cents" => 449 }] })
  end

  # Run ONE Minitest test method and return [passed?, message].
  def run_minitest(&body)
    klass = Class.new(Minitest::Test) do
      include Kiosk::TestHelpers::Conformance::Assertions
      define_method(:test_the_one_thing, &body)
    end
    result = klass.new(:test_the_one_thing).run
    [result.passed?, result.failures.map(&:message).join("\n")]
  end

  describe "Minitest assertions" do
    it "passes on a conforming origin and COUNTS the assertion" do
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

    it "fails on the descriptor lie" do
      origin = lying_origin
      passed, message = run_minitest { assert_kiosk_answer_matches_declared_schema(:catalog, origin: origin) }

      expect(passed).to be(false)
      expect(message).to include("rendered a payload its own output_schema rejects")
    end

    it "reaches all four checks" do
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
      expect(message).to include("leaked")
    end

    it "honours an explicit message" do
      origin = lying_origin
      _, message = run_minitest do
        assert_kiosk_answer_matches_declared_schema(:catalog, origin: origin, message: "catalog lies")
      end

      expect(message).to include("catalog lies")
    end

    it "reports the wiring hint when no origin is configured" do
      # Minitest turns an exception inside a test method into a recorded
      # error, so the hint reaches the operator through the run result rather
      # than by propagating out of it.
      passed, message = run_minitest { assert_kiosk_verbs_routed }

      expect(passed).to be(false)
      expect(message).to include("has no origin configured")
      expect(message).to include("ConformanceOrigin")
    end
  end

  describe "RSpec matchers" do
    before { Kiosk::TestHelpers::Conformance.origin = honest_origin }

    it "passes on a conforming origin" do
      expect(kiosk_origin).to have_a_route_for_every_verb
      expect(:catalog).to execute_as_a_kiosk_verb
      expect(:catalog).to answer_its_declared_schema
    end

    it "falls back to the configured origin when handed nil" do
      expect(nil).to have_a_route_for_every_verb
    end

    it "fails on the descriptor lie" do
      Kiosk::TestHelpers::Conformance.origin = lying_origin

      expect { expect(:catalog).to answer_its_declared_schema }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError,
                        /rendered a payload its own output_schema rejects/)
    end

    it "forwards params: and as: to the check" do
      expect(:catalog).to execute_as_a_kiosk_verb(params: { "q" => 1 }, as: :alice)

      expect(honest_origin.calls.last).to include(params: { "q" => 1 }, as: :alice)
    end

    it "runs the scoping matcher with both principals" do
      origin = null_origin.new(
        verbs:   [lying_verb],
        answers: { %w[catalog].first => nil,
                   ["catalog", :alice] => [{ "price_cents" => 1 }],
                   ["catalog", :bob]   => [{ "price_cents" => 2 }] },
      )
      Kiosk::TestHelpers::Conformance.origin = origin

      expect(:catalog).to be_scoped_to_principal(as: :alice, and_not: :bob)
    end
  end

  describe "the two adapters report the SAME sentence" do
    it "for a descriptor lie" do
      origin = lying_origin
      _, minitest_message = run_minitest do
        assert_kiosk_answer_matches_declared_schema(:catalog, origin: origin)
      end

      Kiosk::TestHelpers::Conformance.origin = lying_origin
      rspec_message =
        begin
          expect(:catalog).to answer_its_declared_schema
          nil
        rescue RSpec::Expectations::ExpectationNotMetError => e
          e.message
        end

      core_message = Kiosk::TestHelpers::Conformance::Checks
                     .declared_shape(lying_origin, :catalog).message

      expect(minitest_message).to include(core_message)
      expect(rspec_message).to include(core_message)
    end

    it "for a verb that is not declared at all" do
      origin = honest_origin
      _, minitest_message = run_minitest { assert_kiosk_verb_executes(:catalogue, origin: origin) }

      Kiosk::TestHelpers::Conformance.origin = honest_origin
      rspec_message =
        begin
          expect(:catalogue).to execute_as_a_kiosk_verb
          nil
        rescue RSpec::Expectations::ExpectationNotMetError => e
          e.message
        end

      expect(minitest_message).to include('no verb named "catalogue"')
      expect(rspec_message).to include('no verb named "catalogue"')
    end
  end
end
