# frozen_string_literal: true

# THE TWO SENTENCES philslist's OWNER-SCOPED VERBS SHARE — the shape of a
# `listing_id` and the refusal an owner-scoped UPDATE earns when it touches no
# row — expressed once, as REFUSALS rather than as rendered responses (the
# {ListAccess} shape tudu settled, and {WireArguments} on hoteling, skooti and
# getgrocery).
#
# WHY THE SHAPE GUARD EXISTS AT ALL, and why it did not shrink when the SQL went
# away. `listing_id` used to be interpolated into a `::uuid` cast, so POSTGRES
# was the shape check: a malformed id raised InvalidTextRepresentation, which is
# not a Kiosk error and so escaped as a raw 500 leaking "invalid input syntax for
# type uuid" for what is plainly a client mistake. That is K-581/K-582, and
# {UuidCheck} was the answer.
#
# The guard got MORE load-bearing under ActiveRecord (K-654), exactly as
# atablefor's, tudu's, skooti's and getgrocery's did: `where(id: junk)` does not
# raise, because ActiveRecord's uuid type quietly casts an unparseable value to
# NULL, which matches no row — so without the check a typo would be reported as
# an OWNERSHIP refusal (403) instead of a shape one (400). ActiveRecord does not
# refuse junk, it CASTS it, and losing the database's refusal is precisely why
# the guard has to be here. A well-formed but foreign id still gets the 403, so
# the shape check never softens the ownership answer.
#
# It is NOT an Operation: it writes nothing. `edit_listing` and `close_listing`
# both reach it — one before an attribute patch, one before a status flip — so
# one malformed-id sentence and one not-yours sentence serve both. There is no
# access DECISION here to put on the model, and that is the interesting part of
# this demo: ownership is not asked as a predicate at all, it is the ROW COUNT of
# `Listing.owned_by_current_principal.where(id:).update_all(…)`, which is what
# keeps the test and the write in one statement that no other transaction can
# slip between. So what is shared is the refusal, not the check.
module ListingAccess
  module_function

  # The listing both owner-scoped verbs act on. SHAPE ONLY — see the header.
  #
  # No presence check, deliberately: `listing_id` is `required` in both
  # descriptors and nothing at the wire enforces that, so an omitted one arrives
  # as nil and reads `listing_id "" is not a uuid`, which is the sentence these
  # verbs have always answered with. Adding a second "you gave me none" sentence
  # here would be a new wire answer, not a conversion.
  #
  # @return [Array(String, nil), Array(nil, OperationResult)]
  def listing_id(raw)
    return [raw, nil] if UuidCheck.valid?(raw)

    [nil, OperationResult.refused(
      code:    "bad_request",
      message: "listing_id #{raw.to_s.inspect} is not a uuid",
      hint:    "Pass a `listing_id` from my_listings / browse_listings, verbatim.",
    )]
  end

  # The owner-scoped miss. Deliberately ONE answer for "no such listing" and
  # "not yours": distinguishing them would let a caller enumerate other owners'
  # listing ids. The verb is the caller's to supply — the hint names the thing
  # the caller was trying to do.
  #
  # @param verb [String] "edit" | "close"
  # @return [OperationResult]
  def not_owner(verb)
    OperationResult.refused(
      code:    "forbidden",
      message: "listing not owned by the authenticated principal",
      hint:    "You may only #{verb} your own listings.",
    )
  end
end
