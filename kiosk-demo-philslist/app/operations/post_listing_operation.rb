# frozen_string_literal: true

# Posts an open listing owned by the signed-in seller, as the assistant acting for them.
class PostListingOperation
  def self.call(seller:, category_slug:, title:, body:, price_text:)
    Listing.create!(
      owner_id: seller.user_id,
      category: Category.find_by!(slug: category_slug),
      title: title,
      body: body,
      price_text: price_text,
      created_by_agent_id: seller.agent_id
    )
  end
end
