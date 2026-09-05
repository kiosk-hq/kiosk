# frozen_string_literal: true

# §8.3 — A DESCRIPTOR'S PUBLISHED EXAMPLES, AGAINST THAT DESCRIPTOR'S OWN
# SCHEMAS. Matrix SPEC-084.
#
# WHY THIS EXISTS. A descriptor publishes `example_params` so an assistant can
# copy one verbatim as its first call, and `example_row` so it knows the shape
# to expect back. The spec says an example ILLUSTRATES the contract and the
# SCHEMA is the contract where the two disagree — which is precisely the
# sentence that lets an example be WRONG with every suite green. e2e's
# `schema_conformance.rb` §4 closes that hole for the reference origin, but it
# runs against the e2e app only, and the seven operator origins publish far
# richer descriptors. This is the same check for them. The defect it catches is
# a small one to write and an expensive one to relay — an integer id published
# as the example for a `uuid` column, so the first call an assistant copies
# verbatim is refused by the origin that published it.
#
# THE BYTES ARE THE SERVED ONES. `demo:schema` hands this the `queries` and
# `actions` arrays `script/schema_flow.rb` GOT off `/kiosk/schema` over HTTP,
# so what is validated is what an assistant actually reads — not what a
# controller file says. Hand-written examples on one side, code checked against
# its own specs on the other, and the two never meeting, is the gap this closes
# — and the reason a source read would not do.
#
# `limit` AND `cursor` ARE EXEMPT, AND THE ENGINE SAYS WHICH ONES. Spec §8.1
# item 6 and §8.4 make them RESERVED names the wire always accepts and a verb
# never declares, so an `input_schema` carrying `additionalProperties: false`
# still accepts them and an `example_params` may legitimately show one —
# hoteling's `search_hotels` publishes `limit: 20` and the origin answers 200.
# {Kiosk::Server::RequestValidation#validate_arguments!} drops exactly this set
# before validating a real request, so a checker that did not would refuse an
# example the origin accepts. The set is READ from
# {Kiosk::Server::ArgumentDecoder::RESERVED} rather than restated here: a
# second copy of a frozen constant is the drift this file would otherwise add.
# A verb that DOES declare one is held to its own declaration, exactly as at
# runtime — the more specific statement wins.
#
# ONE FILE, SEVEN COPIES, declared in bin/check-demo-copies: nothing in it is
# per-demo. What IS per-demo is the `minimum:` the caller passes — how many
# examples that origin publishes — because a loop over an empty list asserts
# nothing and passes silently, which is the failure mode this check would
# otherwise acquire the first time a refactor stopped publishing examples.

require "json"
require "json_schemer"
require "kiosk/server/argument_decoder"

DESCRIPTOR_EXAMPLE_META = "https://json-schema.org/draft/2020-12/schema"

# `example_row` is ONE ELEMENT of the answer. A query's `output_schema` is an
# array schema (§8.2), so the row is checked against its `items` with the
# sibling keywords — `$defs` above all — kept in scope, because `items` is
# routinely a `$ref` into them. An action answers the object itself.
def descriptor_example_row_schema(output_schema)
  return output_schema unless output_schema.is_a?(Hash) &&
                              output_schema["type"] == "array" &&
                              output_schema["items"]

  output_schema.reject { |key, _| %w[type description items].include?(key) }
               .merge(output_schema["items"].is_a?(Hash) ? output_schema["items"] : {})
end

# Validate every published example in a SERVED catalog against the schema its
# own descriptor declares.
#
# @param queries [Array<Hash>] the served `queries` array, JSON-parsed
# @param actions [Array<Hash>] the served `actions` array, JSON-parsed
# @param minimum [Integer] how many examples this origin publishes — the
#   non-vacuity floor; fewer means the loop stopped asserting things
# @return [Array<String>] the failures, empty when every example conforms
def descriptor_example_failures(queries:, actions:, minimum:)
  failures = []
  checked  = 0
  exempt_names = Kiosk::Server::ArgumentDecoder::RESERVED.keys

  { "query" => Array(queries), "action" => Array(actions) }.each do |kind, list|
    list.each do |descriptor|
      name = descriptor["name"]

      if descriptor.key?("example_params")
        declared = descriptor["input_schema"]
        if declared.nil?
          failures << "#{name}: publishes example_params but no input_schema to check it against"
          puts "  ✗  #{kind} #{name}: example_params with no input_schema"
        else
          # The reserved names the ORIGIN would exempt, minus any this verb
          # declares for itself. Same subtraction, same order, as the engine's.
          properties = Kiosk::Server::ArgumentDecoder.fetch(declared, :properties)
          exempt  = exempt_names - (properties.is_a?(Hash) ? properties.keys.map(&:to_s) : [])
          payload = descriptor["example_params"]
          payload = payload.reject { |key, _| exempt.include?(key) } if payload.is_a?(Hash)
          errors  = JSONSchemer.schema(declared, meta_schema: DESCRIPTOR_EXAMPLE_META)
                               .validate(payload).to_a
          checked += 1
          if errors.empty?
            puts "  ✓  #{kind} #{name}: example_params satisfies its own input_schema"
          else
            failures << "#{name}: example_params VIOLATES its own input_schema — " \
                        "#{errors.first(3).map { |e| e["error"] }.join("; ")} (§8.3, SPEC-084)"
            puts "  ✗  #{kind} #{name}: example_params VIOLATES its own input_schema"
          end
        end
      end

      next unless descriptor.key?("example_row")

      declared = descriptor["output_schema"]
      if declared.nil?
        failures << "#{name}: publishes example_row but no output_schema to check it against"
        puts "  ✗  #{kind} #{name}: example_row with no output_schema"
        next
      end

      row_schema = descriptor_example_row_schema(declared)
      next if row_schema == true || row_schema.nil?

      errors = JSONSchemer.schema(row_schema, meta_schema: DESCRIPTOR_EXAMPLE_META)
                          .validate(descriptor["example_row"]).to_a
      checked += 1
      if errors.empty?
        puts "  ✓  #{kind} #{name}: example_row satisfies its own output_schema"
      else
        failures << "#{name}: example_row VIOLATES its own output_schema — " \
                    "#{errors.first(3).map { |e| e["error"] }.join("; ")} (§8.3, SPEC-084)"
        puts "  ✗  #{kind} #{name}: example_row VIOLATES its own output_schema"
      end
    end
  end

  if checked >= minimum
    puts "  ✓  …across #{checked} published examples (the loop is not empty)"
  else
    failures << "only #{checked} descriptor examples were found in the SERVED catalog, " \
                "fewer than the #{minimum} this origin publishes — the §8.3 loop above " \
                "asserted almost nothing (T-097)"
    puts "  ✗  only #{checked} published examples found, want at least #{minimum}"
  end

  failures
end
