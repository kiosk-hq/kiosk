# frozen_string_literal: true

# THE SHAPE GUARD skooti's argument-taking verbs open with — expressed once, as
# a REFUSAL rather than as a rendered response, so both halves of the origin use
# it: the query handlers directly, the write Operations before they touch a
# transaction. It writes nothing, so it is not an Operation.
#
# Load-bearing under ActiveRecord (K-654): `where(id: junk)` does not raise,
# because ActiveRecord's uuid type quietly casts an unparseable value to NULL,
# which matches no row — so without this check a typo would be reported as an
# OWNERSHIP refusal (403) instead of a shape one (400). A well-formed but
# foreign id still gets the 403, so the shape check never softens the access
# answer.
module WireArguments
  module_function

  # The reservation both rental verbs act on.
  #
  # @return [Array(String, nil), Array(nil, OperationResult)]
  #
  # Two refusals, and the split between them is BEHAVIOUR, not taste. `blank?`
  # answers the first: an absent key, an explicit `null`, `""`, `"   "` — and
  # `false`, because `false.blank?` is true — are all "you did not give me one".
  # Anything else that is not a uuid is "you gave me the wrong thing", and that
  # sentence names where a right one comes from.
  def reservation_id(raw)
    return [nil, missing("reservation_id")] if raw.blank?
    return [raw, nil] if UuidCheck.valid?(raw)

    [nil, OperationResult.refused(
      code:    "bad_request",
      message: "reservation_id #{raw.to_s.inspect} is not a uuid — pass the `reservation_id` " \
               "that reserve returned (also listed by my_reservations)",
    )]
  end

  # The refusal for an argument a verb was not given.
  def missing(field)
    OperationResult.refused(code: "bad_request", message: "missing field: #{field}")
  end
end
