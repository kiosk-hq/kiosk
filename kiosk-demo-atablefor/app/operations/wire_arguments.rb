# frozen_string_literal: true

# THE SHAPE GUARDS atablefor's verbs open with — expressed once, as REFUSALS
# rather than as rendered responses (the {ListAccess} shape tudu settled, and
# {WireArguments} on hoteling, skooti and getgrocery).
#
# `party_size` IS THE REASON THIS FILE EXISTS, and it is the one guard on this
# origin genuinely shared between the two halves of the wire: `availability` (a
# query) and `book_table` (an action) both refuse a party of zero, with the SAME
# sentence, because a party size that cannot be shown a table cannot be booked
# one either. It was written out twice before this conversion — in two controllers
# that share no superclass but ApplicationController — and two copies of a
# refusal sentence is two chances for one of them to drift where nobody would
# notice, since neither surface reads the other.
#
# `booking_id` has ONE caller today (`cancel_booking`) and lives here anyway,
# next to its sibling, because it is the same KIND of thing: the shape a wire
# argument must have before any predicate is allowed to look at it. Its own
# reason is K-581/K-582 — the id used to be interpolated into a `::uuid` cast, so
# POSTGRES was the shape check, and a malformed one raised
# InvalidTextRepresentation, which is not a Kiosk error and so escaped as a raw
# 500 leaking "invalid input syntax for type uuid" for what is plainly a client
# mistake. The guard got MORE load-bearing under ActiveRecord (K-654):
# `where(id: junk)` does not raise, because ActiveRecord's uuid type quietly
# casts an unparseable value to NULL, which matches no row — so without the check
# a typo would be reported as an OWNERSHIP refusal (403) instead of a shape one
# (400). ActiveRecord does not refuse junk, it CASTS it, and losing the database's
# refusal is precisely why the guard has to be here. A well-formed but foreign id
# still gets the 403, so the shape check never softens the ownership answer.
#
# These are NOT Operations: they write nothing. Both halves use them — the query
# handler directly, the write Operations before they touch a transaction — so one
# malformed-argument sentence serves the whole origin.
module WireArguments
  module_function

  # The party a caller wants seated.
  #
  # RANGE ONLY. Whether the argument was GIVEN is asked separately, by
  # `availability`, because only that verb distinguishes it: an ABSENT party_size
  # and a party_size that is present but unusable are two different mistakes and
  # keep their two different messages there, while `book_table` has always
  # answered both with this one. Folding presence in here would give book_table a
  # sentence it never had.
  #
  # @return [Array(Integer, nil), Array(nil, OperationResult)]
  def party_size(raw)
    size = raw.to_i
    return [size, nil] if size >= 1

    [nil, OperationResult.refused(code: "bad_request", message: "party_size must be >= 1")]
  end

  # The sentence `availability` answers for a party_size it was not GIVEN at all
  # — the one `params.fetch(:party_size) { raise }` used to produce, kept
  # verbatim. It lives here rather than in the query controller so that BOTH of
  # that verb's party_size answers are written in the same file as the one it
  # shares with `book_table`, and so the controller needs no refusal vocabulary of
  # its own beyond `render_refusal`. `book_table` deliberately does not use it: it
  # has always answered an absent party the same way it answers a zero one.
  def missing_party_size
    OperationResult.refused(code: "bad_request", message: "missing param: party_size")
  end

  # The booking `cancel_booking` acts on: PRESENT, then shaped like an id.
  #
  # Two refusals, and the split between them is BEHAVIOUR, not taste. `blank?`
  # answers the first: an absent key, an explicit `null`, `""`, `"   "` — and
  # `false`, because `false.blank?` is true — are all "you did not give me one",
  # which is the sentence this verb has always answered with. Anything else that
  # is not a uuid is "you gave me the wrong thing", and that sentence names where
  # a right one comes from.
  #
  # @return [Array(String, nil), Array(nil, OperationResult)]
  def booking_id(raw)
    if raw.blank?
      return [nil, OperationResult.refused(code: "bad_request", message: "missing field: booking_id")]
    end
    return [raw, nil] if UuidCheck.valid?(raw)

    [nil, OperationResult.refused(
      code:    "bad_request",
      message: "booking_id #{raw.to_s.inspect} is not a uuid — pass the `booking_id` " \
               "that book_table returned (also listed by my_bookings)",
    )]
  end
end
