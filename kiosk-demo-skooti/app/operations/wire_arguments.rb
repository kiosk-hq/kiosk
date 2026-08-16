# frozen_string_literal: true

# THE SHAPE GUARD skooti's argument-taking verbs open with — expressed once, as
# a REFUSAL rather than as a rendered response (the {ListAccess} shape tudu
# settled, and hoteling's {WireArguments} one demo over).
#
# WHY IT EXISTS AT ALL, and why it did not shrink when the SQL went away.
# `reservation_id` used to be interpolated into a `::uuid` cast, so POSTGRES was
# the shape check: a malformed id raised InvalidTextRepresentation, which is not
# a Kiosk error and so escaped as a raw 500 leaking "invalid input syntax for
# type uuid" for what is plainly a client mistake. That is K-581/K-582, and
# {UuidCheck} was the answer.
#
# The guard got MORE load-bearing under ActiveRecord (K-654), exactly as
# atablefor's and tudu's did: `where(id: junk)` does not raise, because
# ActiveRecord's uuid type quietly casts an unparseable value to NULL, which
# matches no row — so without this check a typo would be reported as an
# OWNERSHIP refusal (403) instead of a shape one (400). ActiveRecord does not
# refuse junk, it CASTS it, and losing the database's refusal is precisely why
# the guard has to be here. A well-formed but foreign id still gets the 403, so
# the shape check never softens the access answer.
#
# It is NOT an Operation: it writes nothing. Both halves use it — the query
# handlers directly, the write Operations before they touch a transaction — so
# one malformed-argument sentence serves the whole origin.
module WireArguments
  module_function

  # The reservation both rental verbs act on.
  #
  # @return [Array(String, nil), Array(nil, OperationResult)]
  #
  # Two refusals, and the split between them is BEHAVIOUR, not taste. `blank?`
  # answers the first: an absent key, an explicit `null`, `""`, `"   "` — and
  # `false`, because `false.blank?` is true — are all "you did not give me one",
  # which is the sentence the raw handler raised and is kept verbatim. Anything
  # else that is not a uuid is "you gave me the wrong thing", and that sentence
  # names where a right one comes from.
  def reservation_id(raw)
    return [nil, missing("reservation_id")] if raw.blank?
    return [raw, nil] if UuidCheck.valid?(raw)

    [nil, OperationResult.refused(
      code:    "bad_request",
      message: "reservation_id #{raw.to_s.inspect} is not a uuid — pass the `reservation_id` " \
               "that reserve returned (also listed by my_reservations)",
    )]
  end

  # The sentence every verb raised for an argument it was not given, unchanged.
  def missing(field)
    OperationResult.refused(code: "bad_request", message: "missing field: #{field}")
  end
end
