# frozen_string_literal: true

# Removes a member from one of the principal's own lists. A list keeps at least one owner.
class RemoveMemberOperation
  def self.call(list_id:, account_id:)
    ListAccess.owner!(list_id)

    owners = Membership.where(list_id: list_id).owner.pluck(:account_id)
    if owners.one? && owners.first.casecmp?(account_id)
      raise Kiosk::Server::Errors::Forbidden.new("cannot remove the list's last owner",
                                                 hint: "A list must keep at least one owner.")
    end

    if Membership.where(list_id: list_id, account_id: account_id).delete_all.zero?
      raise Kiosk::Server::Errors::Forbidden.new("no such membership on this list",
                                                 hint: "The account is not a member of this list.")
    end

    Kiosk::Server::Events.emit(
      topic: :list_membership, subject: list_id,
      identity_scope: Membership.account_ids_on(list_id),
      data: { "account_id" => account_id, "action" => "removed" },
    )

    { removed: true }
  end
end
