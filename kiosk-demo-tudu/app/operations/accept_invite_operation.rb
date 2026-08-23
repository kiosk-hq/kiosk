# frozen_string_literal: true

# accept_invite — redeem a collaboration code: join the list as a member, and
# burn the code. Two database guarantees are load-bearing; see each in place.
class AcceptInviteOperation
  def self.call(principal_id:, code:)
    text = code.to_s
    # Every refusal below is the SAME sentence on purpose: unknown, expired,
    # redeemed and someone-else's are one answer, so a bad code teaches nothing.
    return refused if text.empty?

    digest = Invite.digest(text)

    # Joins the request's SessionContext transaction (see CreateListOperation), so
    # each `next` below leaves the block with a value rather than exiting it.
    Invite.transaction do
      # ── GUARANTEE 1: SELECT … FOR UPDATE ────────────────────────────────
      # A second redeemer BLOCKS here until this request commits, then finds
      # `redeemed_at` set; without the lock both read a virgin row and both
      # "succeed". `find_by` and NOT `find_by!`: the bang form's RecordNotFound
      # renders 404, telling a prober the code is unknown instead of the 403.
      invite = Invite.lock.find_by(code_digest: digest)
      next refused if invite.nil?
      next refused unless invite.redeemed_at.nil?
      # App clock on both ends — see InviteOperation::TTL_SECONDS. Strictly `<`.
      next refused if invite.expires_at < Time.current

      # ── GUARANTEE 2: ON CONFLICT (list_id, account_id) DO NOTHING ────────
      # `insert_all` + `unique_by:` emits exactly that against the UNIQUE index.
      # DO NOTHING and not an upsert: the owner redeeming her own code is already
      # a member with role 'owner', and an upsert would DOWNGRADE her to 'member'.
      Membership.insert_all(
        [{ list_id: invite.list_id, account_id: principal_id, role: Membership::MEMBER }],
        unique_by: %i[list_id account_id],
      )

      # `update_columns`, not `update!`: one UPDATE by primary key, no validations
      # (whose RecordInvalid the floor renders 422) and no callbacks.
      invite.update_columns(redeemed_at: Time.current, redeemed_by_account_id: principal_id)

      OperationResult.ok({ "list_id" => invite.list_id, "joined" => true })
    end
  end

  def self.refused
    OperationResult.refused(
      code:    "forbidden",
      message: "invite code is invalid, expired, or already used",
      hint:    "Ask the list owner for a fresh code.",
    )
  end
  private_class_method :refused
end
