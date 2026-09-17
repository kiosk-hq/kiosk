# frozen_string_literal: true

# THE TWO SENTENCES philslist's OWNER-SCOPED VERBS SHARE — the shape of a
# `listing_id`, and the refusal an owner-scoped UPDATE earns when it touches no
# row — expressed once, as REFUSALS rather than as rendered responses.
#
# WHICH DOOR THE SHAPE GUARD IS FOR, because on the wire it is not the first
# refusal. `edit_listing` and `close_listing` both declare `listing_id` with
# `format: "uuid"`, and a verb's arguments are validated before any handler
# runs, so an assistant that sends a typo already has a 400 naming the field.
# This is the SECOND door — a console, a rake task, or an operator copying this
# module onto a surface with no schema in front of it — and there it is the only
# thing standing between a typo and the wrong answer: ActiveRecord does not
# refuse a malformed uuid, it CASTS it to NULL, which matches no row, so the
# typo would read as an OWNERSHIP refusal (403) rather than the shape one (400)
# it is. A well-formed but foreign id still gets the 403, on either door.
# `rake demo:access_spec` is what holds this module; `demo:redteam`'s
# MalformedUuidArg beat reads the WIRE, where the declaration answers first.
#
# It is NOT an Operation: it writes nothing, and there is no access DECISION to
# put on the model. Ownership is not asked as a predicate at all — it is the ROW
# COUNT of `Listing.owned_by_current_principal.where(id:).update_all(…)`, which
# keeps test and write in one statement no other transaction can slip between.
module ListingAccess
  module_function

  # The listing both owner-scoped verbs act on. SHAPE ONLY — see the header.
  # No presence check, deliberately: `listing_id` is `required` in both
  # descriptors but nothing at the wire enforces that, so an omitted one arrives
  # as nil and reads `listing_id "" is not a uuid`.
  #
  # @return [Array(String, nil), Array(nil, OperationResult)]
  def listing_id(raw)
    return [raw, nil] if Kiosk::UuidCheck.valid?(raw)

    [nil, OperationResult.refused(
      code:    "bad_request",
      message: "listing_id #{raw.to_s.inspect} is not a uuid",
      hint:    "Pass a `listing_id` from my_listings / browse_listings, verbatim.",
    )]
  end

  # The owner-scoped miss. Deliberately ONE answer for "no such listing" and
  # "not yours": distinguishing them would let a caller enumerate other owners'
  # listing ids. The hint names what the caller was trying to do.
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
