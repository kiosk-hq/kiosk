# frozen_string_literal: true

# Redeems an invite: the principal joins the list as a member, and the code is spent.
class AcceptInviteOperation
  def self.call(principal_id:, code:)
    Invite.transaction do
      # Locked, so two redeemers of one code cannot both succeed.
      invite = Invite.redeemable.lock.find_by(code_digest: Invite.digest(code))
      unless invite
        raise Kiosk::Server::Errors::Forbidden.new("invite code is invalid, expired, or already used",
                                                   hint: "Ask the list owner for a fresh code.")
      end

      # An existing membership is left as it is: an owner redeeming her own code stays the owner.
      Membership.insert_all([{ list_id: invite.list_id, account_id: principal_id, role: :member }],
                            unique_by: %i[list_id account_id])
      invite.update!(redeemed_at: Time.current, redeemed_by_account_id: principal_id)

      Kiosk::Server::Events.emit(
        topic: :list_membership, subject: invite.list_id,
        identity_scope: Membership.account_ids_on(invite.list_id),
        data: { "account_id" => principal_id, "role" => "member", "action" => "joined" },
      )

      { list_id: invite.list_id, joined: true }
    end
  end
end
