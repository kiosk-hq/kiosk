# frozen_string_literal: true

require 'kiosk/reputation'

# The check that makes the wrong verb spelling loud.
#
# The seam hands a policy one of {Kiosk::Server::Executor::VERBS} — `:query`,
# `:run`, `:pay` — and a handler declared `kind :action` arrives as `:run`.
# A policy branching on `:action` matches nothing, returns nil, and nil is the
# ordinary "do not toll this one" answer: no error, no log line, and the toll
# never applies to a single write.
#
# Two kinds of example prove the check READS the source:
#
#   * "returns :clean" (and the shipped-policy example) fail if the parser
#     stops finding the hook, which would make the check a silent no-op.
#   * "does not flag :action outside a comparison" fails if the check
#     degrades into a bare search for the word, which would refuse correct
#     policies.
#
# "the seam's premise" pins the fact the check rests on: the gate vocabulary
# is `%i[query run pay]`.
module VerbVocabularySpec
  def correctly_spelled_policy
    Class.new(Kiosk::Reputation::Policy) do
      def challenge_for(verb:, **)
        return nil unless verb == :run

        { alg: 'argon2id', params: { d: 4, m: 8 } }
      end
    end.new
  end

  def policy_comparing_to_action
    Class.new(Kiosk::Reputation::Policy) do
      def challenge_for(verb:, **)
        return nil unless verb == :action

        { alg: 'argon2id', params: { d: 4, m: 8 } }
      end
    end.new
  end

  def policy_casing_on_action
    Class.new(Kiosk::Reputation::Policy) do
      def challenge_for(verb:, **)
        case verb
        when :action then { alg: 'argon2id', params: { d: 4, m: 8 } }
        end
      end
    end.new
  end

  def policy_including_action
    Class.new(Kiosk::Reputation::Policy) do
      def challenge_for(verb:, **)
        return nil unless %i[action pay].include?(verb)

        { alg: 'argon2id', params: { d: 4, m: 8 } }
      end
    end.new
  end

  def policy_naming_action_outside_a_comparison
    Class.new(Kiosk::Reputation::Policy) do
      def challenge_for(verb:, **)
        # A hash key, a string, and a comment mentioning :action are not
        # branches. Only a comparison against the verb is.
        table = { action: 2, query: 1 }
        return nil unless verb == :run

        { alg: 'argon2id', params: { d: 4, m: 8 }, count: table[:action] }
      end
    end.new
  end
end

RSpec.describe Kiosk::Server::VerbVocabulary do
  include VerbVocabularySpec

  # ── the premise ────────────────────────────────────────────────────────────

  describe "the seam's premise" do
    it 'is that the gate vocabulary names the write kind :run, not :action' do
      expect(Kiosk::Server::Executor::VERBS).to include(described_class::WRITE_KIND)
      expect(Kiosk::Server::Executor::VERBS).not_to include(described_class::DECLARATION_ALIAS)
      expect(described_class::WRITE_KIND).to eq(:run)
      expect(described_class::DECLARATION_ALIAS).to eq(:action)
    end
  end

  # ── the check reads real source ────────────────────────────────────────────

  describe 'a correctly spelled policy' do
    let(:policy) { correctly_spelled_policy }

    it "returns :clean — proving the hook's source was found and parsed" do
      expect(described_class.assert!(policy, :challenge_for, 'policy')).to eq(:clean)
    end

    it 'is accepted by the configuration writer' do
      expect { Kiosk.configure { |c| c.reputation_policy = policy } }.not_to raise_error
      expect(Kiosk.configuration.reputation_policy).to be(policy)
    end
  end

  it 'reads the SHIPPED policies as clean' do
    expect(described_class.assert!(Kiosk::Reputation::Policy.new, :challenge_for, 'base')).to eq(:clean)
    expect(
      described_class.assert!(Kiosk::Reputation::Policies::RateAndReputation.new, :challenge_for, 'rate')
    ).to eq(:clean)
  end
end

# ── the refusals ─────────────────────────────────────────────────────────────
RSpec.describe Kiosk::Server::VerbVocabulary do
  include VerbVocabularySpec

  describe 'a policy branching on the declaration spelling' do
    it 'is refused with a message naming :run' do
      expect { described_class.assert!(policy_comparing_to_action, :challenge_for, 'policy') }
        .to raise_error(Kiosk::Server::Errors::ConfigurationError, /branches on :action/)
      expect { described_class.assert!(policy_comparing_to_action, :challenge_for, 'policy') }
        .to raise_error(Kiosk::Server::Errors::ConfigurationError, /arrives as :run/)
    end

    it 'is refused when the branch is a case/when' do
      expect { described_class.assert!(policy_casing_on_action, :challenge_for, 'policy') }
        .to raise_error(Kiosk::Server::Errors::ConfigurationError)
    end

    it 'is refused when the branch is an array inclusion' do
      expect { described_class.assert!(policy_including_action, :challenge_for, 'policy') }
        .to raise_error(Kiosk::Server::Errors::ConfigurationError)
    end

    it 'is refused AT CONFIGURATION TIME, not at the first tolled write' do
      expect { Kiosk.configure { |c| c.reputation_policy = policy_comparing_to_action } }
        .to raise_error(Kiosk::Server::Errors::ConfigurationError)
    end
  end
end

RSpec.describe Kiosk::Server::VerbVocabulary do
  it 'refuses a reputation_factors callable that branches on :action' do
    factors = ->(verb:, **) { Kiosk::Reputation::Factors.empty if verb == :action }

    expect { Kiosk.configure { |c| c.reputation_factors = factors } }
      .to raise_error(Kiosk::Server::Errors::ConfigurationError, /reputation_factors/)
  end
end

RSpec.describe Kiosk::Server::VerbVocabulary do
  include VerbVocabularySpec

  # ── the false-positive control ─────────────────────────────────────────────

  it 'does not flag :action outside a comparison' do
    policy = policy_naming_action_outside_a_comparison

    expect(described_class.assert!(policy, :challenge_for, 'policy')).to eq(:clean)
  end

  # ── what it cannot read says so, and never raises ──────────────────────────

  it 'is silent about an object that does not answer the hook at all' do
    expect(described_class.assert!(Object.new, :challenge_for, 'policy')).to eq(:unreadable)
    expect { Kiosk.configure { |c| c.reputation_policy = Object.new } }.not_to raise_error
  end

  it 'is silent about a hook with no readable source' do
    policy = Class.new(Kiosk::Reputation::Policy) do
      define_method(:challenge_for) { |**| nil }
    end.new
    allow(File).to receive(:readable?).and_return(false)

    expect(described_class.assert!(policy, :challenge_for, 'policy')).to eq(:unreadable)
  end

  it 'leaves a nil policy alone' do
    expect { Kiosk.configure { |c| c.reputation_policy = nil } }.not_to raise_error
  end
end
