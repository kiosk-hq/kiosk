# frozen_string_literal: true

# THE LIST-ACCESS PRECONDITION every list-scoped caller shares — shape first,
# then membership — expressed once, as a REFUSAL rather than as a rendered
# response.
#
# Three callers need it and no two of them can render the same way: four
# Operations (add_todo, invite, accept_invite's siblings, remove_member) that
# know no HTTP at all, the Kiosk query handlers that answer `render json:,
# status:`, and the human web controllers that redirect with a flash. Before the
# Operations existed this lived in {KioskMembershipGate} as ~25 lines of
# render-and-return, which is why the gate could not be reused by anything that
# does not render. Splitting the answer from its presentation is what lets all
# three share ONE copy of these two sentences — and a message that drifted in
# one copy would be a wire difference nobody could see.
#
# It is NOT an Operation: it writes nothing, it is a precondition Operations
# consult. It is not on the model either — {Membership.reachable?} is the
# DECISION (a fact about the domain, no request in it) and this is the refusal
# that decision earns, which is a fact about a caller.
module ListAccess
  # @param list_id [Object] the raw wire/URL value — shape is checked here
  # @param require_owner [Boolean] tighten to role='owner' (invite/remove authority)
  # @return [OperationResult, nil] a refusal, or nil when access is granted
  #
  # K-581/K-582: `list_id` arrives from the wire and used to be interpolated
  # into a `::uuid` cast, where a malformed value made Postgres raise
  # InvalidTextRepresentation — not a Kiosk error, so it escaped as a raw 500
  # leaking "invalid input syntax for type uuid" for a plain client mistake.
  # The guard got MORE load-bearing when the SQL became ActiveRecord (K-654),
  # exactly as atablefor's did: `where(list_id: junk)` does not raise, because
  # ActiveRecord's uuid type quietly casts an unparseable value to NULL, which
  # matches no row — so without this check a typo would be reported as an
  # ACCESS refusal (403) instead of a shape one (400). Shape first, then the
  # membership predicate; a well-formed but foreign id still gets the 403, so
  # the shape check never softens the access answer.
  def self.check(list_id, require_owner: false)
    unless UuidCheck.valid?(list_id)
      return OperationResult.refused(
        code:    "bad_request",
        message: "list_id #{list_id.to_s.inspect} is not a uuid",
        hint:    "Pass a `list_id` from my_lists (or the one create_list returned), verbatim.",
      )
    end

    return nil if Membership.reachable?(list_id, require_owner: require_owner)

    # Forbidden (not NotFound) so cross-list probing can't enumerate which ids
    # exist — the philslist pattern, adapted to membership-based access.
    OperationResult.refused(
      code:    "forbidden",
      message: require_owner ? "list not owned by the authenticated principal" \
                             : "list not accessible by the authenticated principal",
      hint:    require_owner ? "Only the list owner may do this." \
                             : "You may only reach lists you are a member of.",
    )
  end
end
