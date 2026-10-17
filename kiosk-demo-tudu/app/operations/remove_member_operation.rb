# frozen_string_literal: true

# Removes a member from one of the caller's own lists. The owner cannot remove themselves.
class RemoveMemberOperation
  def self.call(list_id:, account_id:)
    ListAccess.owner!(list_id)
    refuse_self!(account_id)

    if Membership.where(list_id: list_id, account_id: account_id).delete_all.zero?
      raise Kiosk::Server::Errors::Forbidden.new('no such membership on this list',
                                                 hint: 'Use an account from list_members.')
    end

    announce_removal(list_id, account_id)
  end

  def self.refuse_self!(account_id)
    return unless Kiosk.current_user_id.to_s.casecmp?(account_id.to_s)

    raise Kiosk::Server::Errors::Forbidden.new('the owner cannot remove themselves',
                                               hint: 'Pass the account_id of another member from list_members.')
  end

  def self.announce_removal(list_id, account_id)
    Kiosk::Server::Events.emit(
      topic: :list_membership, subject: list_id,
      identity_scope: Membership.account_ids_on(list_id),
      data: { 'account_id' => account_id, 'action' => 'removed' }
    )
  end
end
