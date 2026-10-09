# frozen_string_literal: true

require "rspec/expectations"

require "kiosk/test_helpers/conformance"

module Kiosk
  module TestHelpers
    module Conformance
      # RSpec matchers for the four conformance checks; required by name only.
      module RSpecHelpers
        def kiosk_origin = Conformance.require_origin!
      end

      # The matcher DSL hands keywords to a block as one positional Hash.
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

# `expect(kiosk_origin).to have_a_route_for_every_verb`
# Without `|options = {}|` a keyword `origin:` would be silently dropped.
RSpec::Matchers.define :have_a_route_for_every_verb do |options = {}|
  match do |origin|
    @outcome = Kiosk::TestHelpers::Conformance::Checks.routes(
      origin || Kiosk::TestHelpers::Conformance::RSpecOptions.origin(options),
    )
    @outcome.ok?
  end

  failure_message { @outcome.message }
  failure_message_when_negated { "expected some verb to be unrouted, but #{@outcome.message}" }
  description { "have a route for every declared verb" }
end

# `expect(:catalog).to execute_as_a_kiosk_verb`
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

# `expect(:catalog).to answer_its_declared_schema`
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

# `expect(:my_orders).to be_scoped_to_principal(as: alice, and_not: bob)`
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
