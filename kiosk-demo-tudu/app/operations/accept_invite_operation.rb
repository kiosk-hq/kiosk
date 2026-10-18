# frozen_string_literal: true

# Redeems an invite: the member joins the list as a member, and the code is spent. Returns the invite.
class AcceptInviteOperation
  def self.call(member_id:, code:)
    Invite.transaction do
      invite = redeemable!(code)
      # An existing membership is left as it is: an owner redeeming her own code stays the owner.
      Membership.find_or_create_by!(list_id: invite.list_id, account_id: member_id) { it.role = :member }
      invite.update!(redeemed_at: Time.current, redeemed_by_account_id: member_id)
      announce_join(invite.list_id, member_id)
      invite
    end
  end

  # Locked, so two redeemers of one code cannot both succeed.
  def self.redeemable!(code)
    invite = Invite.redeemable.lock.find_by(code_digest: Invite.digest(code))
    return invite if invite

    raise Kiosk::Server::Errors::Forbidden.new('invite code is invalid, expired, or already used',
                                               hint: 'Ask the list owner for a fresh code.')
  end

  def self.announce_join(list_id, member_id)
    Kiosk::Server::Events.emit(
      topic: :list_membership, subject: list_id,
      identity_scope: Membership.account_ids_on(list_id),
      data: { 'account_id' => member_id, 'role' => 'member', 'action' => 'joined' }
    )
  end
end
