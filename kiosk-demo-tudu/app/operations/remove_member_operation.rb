# frozen_string_literal: true

# Removes a member from one of the caller's own lists. A list keeps at least one owner.
class RemoveMemberOperation
  def self.call(list_id:, account_id:)
    ListAccess.owner!(list_id)
    keep_last_owner!(list_id, account_id)

    if Membership.where(list_id: list_id, account_id: account_id).delete_all.zero?
      raise Kiosk::Server::Errors::Forbidden.new('no such membership on this list',
                                                 hint: 'Use an account from list_members.')
    end

    announce_removal(list_id, account_id)
  end

  def self.keep_last_owner!(list_id, account_id)
    owners = Membership.where(list_id: list_id).owner.pluck(:account_id)
    return unless owners.one? && owners.first.casecmp?(account_id)

    raise Kiosk::Server::Errors::Forbidden.new("cannot remove the list's last owner",
                                               hint: 'A list must keep at least one owner.')
  end

  def self.announce_removal(list_id, account_id)
    Kiosk::Server::Events.emit(
      topic: :list_membership, subject: list_id,
      identity_scope: Membership.account_ids_on(list_id),
      data: { 'account_id' => account_id, 'action' => 'removed' }
    )
  end
end
