# frozen_string_literal: true

# remove_member — OWNER-ONLY. Cut a member's access to a list instantly, but
# never orphan the list by removing its last owner.
#
# Wire-only today, an Operation for the same reason as AcceptInviteOperation.
class RemoveMemberOperation
  def self.call(list_id:, account_id:)
    refusal = ListAccess.check(list_id, require_owner: true)
    return refusal if refusal

    # `account_id` is a SECOND wire-supplied id and {ListAccess} only covers
    # `list_id`, so it gets its own shape check (K-581/K-582).
    target = account_id.to_s
    unless UuidCheck.valid?(target)
      return OperationResult.refused(
        code:    "bad_request",
        message: "account_id #{target.inspect} is not a uuid",
        hint:    "Pass an `account_id` from list_members, verbatim.",
      )
    end

    # Never remove the list's LAST owner. This was one SQL statement — an
    # EXISTS(target is owner) AND (count(owners) <= 1) — and it stays ONE
    # statement rather than becoming an `exists?` plus a `count`. That is not
    # tidiness: the request runs at READ COMMITTED, where each statement takes
    # its own snapshot, so two statements could straddle a concurrent
    # membership change and answer from two different worlds. Plucking the
    # owners once and deciding in Ruby keeps both facts on one snapshot.
    #
    # `casecmp?` and not `==`: UuidCheck accepts either case (`\h`), and
    # Postgres' `uuid` type compares canonically, so the raw SQL matched an
    # UPPERCASE id that a byte-comparison in Ruby would miss — which would let
    # an owner remove herself by shouting her own id.
    owner_ids = Membership.where(list_id: list_id, role: Membership::OWNER).pluck(:account_id)
    if owner_ids.size <= 1 && owner_ids.any? { |id| id.casecmp?(target) }
      return OperationResult.refused(
        code:    "forbidden",
        message: "cannot remove the list's last owner",
        hint:    "A list must keep at least one owner.",
      )
    end

    # `delete_all`, not `destroy_all`: the raw DELETE ran no callbacks and
    # loaded no rows, and the count IS the answer.
    removed = Membership.where(list_id: list_id, account_id: target).delete_all
    if removed.zero?
      return OperationResult.refused(
        code:    "forbidden",
        message: "no such membership on this list",
        hint:    "The account is not a member of this list.",
      )
    end

    OperationResult.ok({ "removed" => true })
  end
end
