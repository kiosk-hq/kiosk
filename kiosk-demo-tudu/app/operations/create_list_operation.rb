# frozen_string_literal: true

# A new list, owned by the member who creates it.
class CreateListOperation
  def self.call(member_id:, title:)
    List.create!(account_id: member_id, title: title,
                 memberships: [Membership.new(account_id: member_id, role: :owner)])
  end
end
