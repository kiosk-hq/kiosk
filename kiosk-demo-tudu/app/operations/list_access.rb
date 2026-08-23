# frozen_string_literal: true

# THE LIST-ACCESS PRECONDITION every list-scoped caller shares — shape first,
# then membership — expressed once, as a REFUSAL rather than as a rendered
# response. Three kinds of caller need it and no two render the same way:
# Operations that know no HTTP, the Kiosk query handlers that `render json:,
# status:`, and the human web controllers that redirect with a flash — and a
# message that drifted in one copy would be a wire difference nobody could see.
#
# NOT an Operation: it writes nothing. Not on the model either —
# {Membership.reachable?} is the DECISION (a fact about the domain) and this is
# the refusal that decision earns (a fact about a caller).
module ListAccess
  # @param list_id [Object] the raw wire/URL value — shape is checked here
  # @param require_owner [Boolean] tighten to role='owner' (invite/remove authority)
  # @return [OperationResult, nil] a refusal, or nil when access is granted
  #
  # `list_id` arrives from the wire and its shape is load-bearing (K-581/K-582):
  # `where(list_id: junk)` does not raise — ActiveRecord's uuid type quietly casts
  # an unparseable value to NULL, which matches no row — so without this check a
  # typo would be reported as an ACCESS refusal (403) instead of a shape one
  # (400). A well-formed but foreign id still gets the 403.
  def self.check(list_id, require_owner: false)
    unless UuidCheck.valid?(list_id)
      return OperationResult.refused(
        code:    "bad_request",
        message: "list_id #{list_id.to_s.inspect} is not a uuid",
        hint:    "Pass a `list_id` from my_lists (or the one create_list returned), verbatim.",
      )
    end

    return nil if Membership.reachable?(list_id, require_owner: require_owner)

    # Forbidden (not NotFound) so probing can't enumerate which ids exist.
    OperationResult.refused(
      code:    "forbidden",
      message: require_owner ? "list not owned by the authenticated principal" \
                             : "list not accessible by the authenticated principal",
      hint:    require_owner ? "Only the list owner may do this." \
                             : "You may only reach lists you are a member of.",
    )
  end
end
