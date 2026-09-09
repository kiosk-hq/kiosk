# frozen_string_literal: true

require "rspec/expectations"

require "kiosk/test_helpers/conformance"

module Kiosk
  module TestHelpers
    module Conformance
      # RSpec wiring for the four conformance checks.
      #
      # Required by name — `require "kiosk/test_helpers/conformance/rspec"` —
      # and never by `require "kiosk/test_helpers"`, which is what lets this gem
      # depend on no test framework while shipping wiring for two.
      #
      #   require "kiosk/test_helpers/conformance/rspec"
      #
      #   RSpec.describe "the Kiosk wire" do
      #     it "routes every verb it declares" do
      #       expect(kiosk_origin).to have_a_route_for_every_verb
      #     end
      #
      #     it "answers what catalog publishes" do
      #       expect(:catalog).to answer_its_declared_schema
      #     end
      #
      #     it "scopes my_orders to the caller" do
      #       expect(:my_orders).to be_scoped_to_principal(as: alice, and_not: bob)
      #     end
      #   end
      #
      # Every matcher takes the same keywords as the Minitest assertions
      # (`params:`, `as:`, `and_not:`, `origin:`) and renders the same
      # {Outcome#message}, so a fault found in one framework and reproduced in
      # the other reads identically.
      module RSpecHelpers
        # The configured origin, so `expect(kiosk_origin).to …` reads as the
        # sentence it is. Every matcher also falls back to it, so an example
        # that passes nil still works.
        def kiosk_origin = Conformance.require_origin!
      end

      # Shared by the four matchers: the origin to use and the keywords to
      # forward. RSpec's matcher DSL hands a block ONE positional Hash — a
      # keyword call to a matcher is converted on the way in — so the matchers
      # take `|options = {}|` and read it here rather than declaring keyword
      # parameters that would never be filled.
      module RSpecOptions
        module_function

        def origin(options)
          options[:origin] || Conformance.require_origin!
        end

        def params(options)
          options.fetch(:params, Checks::EXAMPLE)
        end
      end
    end
  end
end

# Matcher: `expect(kiosk_origin).to have_a_route_for_every_verb`
#
# Every verb this origin declares has a route, reaching the wire's verb
# controller under its own name, with the method its kind requires. An origin
# that declares NO verbs fails — an empty registry must not read as "all zero of
# my verbs are routed".
RSpec::Matchers.define :have_a_route_for_every_verb do
  match do |origin|
    @outcome = Kiosk::TestHelpers::Conformance::Checks.routes(
      origin || Kiosk::TestHelpers::Conformance.require_origin!,
    )
    @outcome.ok?
  end

  failure_message { @outcome.message }
  failure_message_when_negated { "expected some verb to be unrouted, but #{@outcome.message}" }
  description { "have a route for every declared verb" }
end

# Matcher: `expect(:catalog).to execute_as_a_kiosk_verb`
#
# `params:` defaults to the verb's own `example_params`, so the cheapest true
# assertion an adopter can write also executes the example their descriptor
# publishes.
RSpec::Matchers.define :execute_as_a_kiosk_verb do |options = {}|
  match do |name|
    @outcome = Kiosk::TestHelpers::Conformance::Checks.executes(
      Kiosk::TestHelpers::Conformance::RSpecOptions.origin(options), name,
      params: Kiosk::TestHelpers::Conformance::RSpecOptions.params(options),
      as:     options[:as],
    )
    @outcome.ok?
  end

  failure_message { @outcome.message }
  failure_message_when_negated { "expected #{@outcome.subject} to refuse, but #{@outcome.message}" }
  description { "execute as a Kiosk verb" }
end

# Matcher: `expect(:catalog).to answer_its_declared_schema`
#
# The arguments satisfy the verb's `input_schema` and the answer satisfies its
# `output_schema`. A verb missing either declaration fails rather than skipping:
# both are required of every verb, so an absent one means the origin is not what
# it claims to be.
RSpec::Matchers.define :answer_its_declared_schema do |options = {}|
  match do |name|
    @outcome = Kiosk::TestHelpers::Conformance::Checks.declared_shape(
      Kiosk::TestHelpers::Conformance::RSpecOptions.origin(options), name,
      params: Kiosk::TestHelpers::Conformance::RSpecOptions.params(options),
      as:     options[:as],
    )
    @outcome.ok?
  end

  failure_message { @outcome.message }
  failure_message_when_negated do
    "expected #{@outcome.subject} to answer something its own schema rejects, " \
      "but #{@outcome.message}"
  end
  description { "answer the shape its own output_schema declares" }
end

# Matcher: `expect(:my_orders).to be_scoped_to_principal(as: alice, and_not: bob)`
#
# No row `as:` sees reaches `and_not:` — and `as:` must see something, or the
# matcher fails for having no positive control. A verb declared
# `reach: :published` fails too: it is SUPPOSED to answer both the same.
RSpec::Matchers.define :be_scoped_to_principal do |options = {}|
  match do |name|
    @outcome = Kiosk::TestHelpers::Conformance::Checks.principal_scope(
      Kiosk::TestHelpers::Conformance::RSpecOptions.origin(options), name,
      as:      options.fetch(:as),
      and_not: options.fetch(:and_not),
      params:  Kiosk::TestHelpers::Conformance::RSpecOptions.params(options),
    )
    @outcome.ok?
  end

  failure_message { @outcome.message }
  failure_message_when_negated do
    "expected #{@outcome.subject} to leak across principals, but #{@outcome.message}"
  end
  description { "be scoped to the calling principal" }
end

if defined?(RSpec) && RSpec.respond_to?(:configure)
  RSpec.configure { |config| config.include(Kiosk::TestHelpers::Conformance::RSpecHelpers) }
end
