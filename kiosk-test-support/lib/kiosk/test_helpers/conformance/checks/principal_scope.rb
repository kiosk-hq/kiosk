# frozen_string_literal: true

module Kiosk
  module TestHelpers
    module Conformance
      module Checks
        # No row `as:` sees reaches `and_not:`, compared whole-row. An empty first
        # answer fails (no positive control), and so does a `published` verb.
        module PrincipalScope
          extend Helpers

          # What each principal saw. `refused` is the scoping refusal, or nil.
          Sighting = Data.define(:verb, :as, :and_not, :own, :other, :refused)

          module_function

          def call(origin, name, as:, and_not:, params:)
            verb = find_verb(origin, name)
            return verb if verb.is_a?(Outcome)
            return published(verb) if verb.reach == 'published'

            compare(origin, verb, arguments_for(verb, params), as, and_not)
          end

          def compare(origin, verb, arguments, as, and_not)
            mine = Checks.executes(origin, verb.name, params: arguments, as: as)
            return mine if mine.failed?

            theirs  = Checks.executes(origin, verb.name, params: arguments, as: and_not)
            refused = refusal_status(theirs)
            return theirs if theirs.failed? && refused.nil?

            other = refused ? [] : rows_of(theirs.details[:answer])
            verdict(Sighting.new(verb: verb, as: as, and_not: and_not,
                                 own: rows_of(mine.details[:answer]), other: other, refused: refused))
          end

          def verdict(sighting)
            return nothing_own(sighting) if sighting.own.empty?

            leaked = sighting.own & sighting.other
            leaked.empty? ? scoped(sighting) : leak(sighting, leaked)
          end

          def published(verb)
            Conformance.fail(
              :principal_scope, subject: verb.name,
                                message: "#{verb} declares `reach: :published`, which says every authenticated " \
                                         'caller sees the same rows. Asserting that two principals see different ' \
                                         'rows asserts the opposite of the descriptor — assert the descriptor, or ' \
                                         'narrow the reach.',
                                details: { verb: verb.name, reach: verb.reach }
            )
          end

          def nothing_own(sighting)
            verb = sighting.verb
            Conformance.fail(
              :principal_scope, subject: verb.name,
                                message: "#{verb} answered #{principal_label(sighting.as)} with nothing, so there is nothing for " \
                                         "#{principal_label(sighting.and_not)} to be scoped out of. Seed a row that belongs to the " \
                                         'first principal — a scoping assertion with no positive control passes ' \
                                         'on a verb that answers everybody with nothing.',
                                details: { verb: verb.name, reach: verb.reach, own: sighting.own, other: sighting.other }
            )
          end

          def scoped(sighting)
            verb = sighting.verb
            Conformance.pass(
              :principal_scope, subject: verb.name,
                                message: sighting.refused ? refused_message(sighting) : narrowed_message(sighting),
                                details: { verb: verb.name, reach: verb.reach, own: sighting.own,
                                           other: sighting.other, refused: sighting.refused }
            )
          end

          def refused_message(sighting)
            "#{sighting.verb} answered #{principal_label(sighting.as)} with #{sighting.own.length} row(s) and REFUSED " \
              "#{principal_label(sighting.and_not)} outright (#{sighting.refused}), which is the strongest " \
              "spelling of reach: :#{sighting.verb.reach}"
          end

          def narrowed_message(sighting)
            "#{sighting.verb} answered #{principal_label(sighting.as)} with #{sighting.own.length} row(s), none of " \
              "which reached #{principal_label(sighting.and_not)} (declared reach: #{sighting.verb.reach})"
          end

          def leak(sighting, rows)
            verb = sighting.verb
            Conformance.fail(
              :principal_scope, subject: verb.name,
                                message: "#{verb} is declared `reach: :#{verb.reach}` but leaked #{rows.length} " \
                                         "row(s) belonging to #{principal_label(sighting.as)} into " \
                                         "#{principal_label(sighting.and_not)}'s answer: " \
                                         "#{rows.first(3).inspect}. Scope the handler to the calling principal.",
                                details: { verb: verb.name, reach: verb.reach, leaked: rows }
            )
          end
        end
      end
    end
  end
end
