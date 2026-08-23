# frozen_string_literal: true

# remove_member — OWNER-ONLY. Cut a member's access to a list instantly, but
# never orphan the list by removing its last owner. Wire-only today, an Operation
# for the same reason as AcceptInviteOperation.
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

    # Never remove the list's LAST owner, decided from ONE statement rather than
    # an `exists?` plus a `count`: at READ COMMITTED each statement takes its own
    # snapshot, so two could straddle a concurrent membership change.
    #
    # `casecmp?` and not `==`: UuidCheck accepts either case (`\h`) and Postgres'
    # `uuid` compares canonically, so a byte-comparison would let an owner remove
    # herself by shouting her own id.
    owner_ids = Membership.where(list_id: list_id, role: Membership::OWNER).pluck(:account_id)
    if owner_ids.size <= 1 && owner_ids.any? { |id| id.casecmp?(target) }
      return OperationResult.refused(
        code:    "forbidden",
        message: "cannot remove the list's last owner",
        hint:    "A list must keep at least one owner.",
      )
    end

    # `delete_all`, not `destroy_all`: no callbacks, and the count IS the answer.
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
