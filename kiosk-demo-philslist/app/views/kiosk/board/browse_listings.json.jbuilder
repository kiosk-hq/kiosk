# frozen_string_literal: true

zone = BoardClock.zone
json.array! @listings do |listing|
  json.listing_id listing.id
  json.extract! listing, :title, :body, :price_text
  json.category_slug listing.category.slug
  json.posted_at BoardClock.publish(listing.created_at, zone)
  json.timezone zone.name
  json.owner_handle listing.owner.public_name
end
