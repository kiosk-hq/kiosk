# frozen_string_literal: true

# The refusal a caller gets for a list it may not reach. Forbidden either way,
# so a stranger cannot tell which list ids exist.
module ListAccess
  module_function

  def member!(list_id)
    return if Membership.own.exists?(list_id: list_id)

    raise Kiosk::Server::Errors::Forbidden.new('you are not a member of this list',
                                               hint: 'Use a list from my_lists.')
  end

  def owner!(list_id)
    return if Membership.own.owner.exists?(list_id: list_id)

    raise Kiosk::Server::Errors::Forbidden.new('only the list owner may do this',
                                               hint: 'Ask the list owner.')
  end
end
