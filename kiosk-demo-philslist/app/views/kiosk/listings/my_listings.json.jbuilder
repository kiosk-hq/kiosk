# frozen_string_literal: true
zone = BoardClock.zone
json.array! @listings do |listing|
  json.listing_id listing.id
  json.extract! listing, :title, :price_text, :status
  json.category_slug listing.category.slug
  json.posted_at BoardClock.publish(listing.created_at, zone)
  json.timezone zone.name
end
