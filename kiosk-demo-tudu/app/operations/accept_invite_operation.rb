# frozen_string_literal: true

# accept_invite — redeem a collaboration code: join the list as a member, and
# burn the code.
#
# Wire-only today (no web UI button mints or redeems on someone else's behalf),
# but it is a WRITE, so it is an Operation like its siblings rather than a
# controller method — the seam is about where write logic lives, not about how
# many doors currently reach it.
#
# TWO DATABASE GUARANTEES ARE LOAD-BEARING HERE and both survive the move off
# raw SQL verbatim; see the comments at each one.
class AcceptInviteOperation
  def self.call(principal_id:, code:)
    text = code.to_s
    # Every refusal below is the SAME sentence on purpose — unknown, expired,
    # already-redeemed and someone-else's are one answer, so a caller holding a
    # bad code learns nothing about which codes exist.
    return refused if text.empty?

    digest = Invite.digest(text)

    # Joins the request's SessionContext transaction (see CreateListOperation),
    # so each `next` below leaves the block with a value rather than performing
    # a non-local exit from a real transaction block.
    Invite.transaction do
      # ── GUARANTEE 1: SELECT … FOR UPDATE ────────────────────────────────
      # `.lock` is the row lock, unchanged: a second redeemer of the same code
      # BLOCKS here until this request commits, then re-evaluates and finds
      # `redeemed_at` set. Without it two concurrent redemptions both read a
      # virgin row and both "succeed". `find_by` and NOT `find_by!`: the bang
      # form raises RecordNotFound, which Rails maps to 404, and the mixin's
      # `rescue_from` floor would render `not_found` — turning the deliberately
      # uninformative 403 into a code that tells a prober the code is unknown.
      invite = Invite.lock.find_by(code_digest: digest)
      next refused if invite.nil?
      next refused unless invite.redeemed_at.nil?
      # App clock on both ends — see InviteOperation::TTL_SECONDS for why the
      # write and this comparison had to move together. Strictly `<`, as the
      # `expires_at < now()` it replaces.
      next refused if invite.expires_at < Time.current

      # ── GUARANTEE 2: ON CONFLICT (list_id, account_id) DO NOTHING ────────
      # `insert_all` + `unique_by:` emits exactly that clause against the
      # UNIQUE index. It has to be DO NOTHING and not an upsert: the owner
      # redeeming her own code is already a member with role 'owner', and an
      # upsert would DOWNGRADE her to 'member' — silently stripping her
      # invite/remove authority. A plain `create!`/`insert!` would instead raise
      # RecordNotUnique (a 500) where the raw SQL quietly did nothing.
      Membership.insert_all(
        [{ list_id: invite.list_id, account_id: principal_id, role: Membership::MEMBER }],
        unique_by: %i[list_id account_id],
      )

      # `update_columns`, not `update!`: one UPDATE by primary key, no
      # validations, no callbacks — the faithful translation of the raw UPDATE.
      # `update!` would run `belongs_to :list`'s presence validation (an extra
      # SELECT) and could raise RecordInvalid, which the floor renders 422.
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
