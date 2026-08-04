# frozen_string_literal: true

# Seed hotel properties and room types for the hoteling demo.
# No human users needed — agents self-register via /kiosk/auth/register
# (proof-of-possession handshake).
#
# T-042 / K-452 — SCALE. hoteling seeds ~100 coined Istanbul hotels so an
# unpaginated list would overwhelm an assistant (the "analysis paralysis /
# silent truncation" case). That makes `search_hotels` (paginated,
# multi-parameter) and `hotel_detail` (fetch one) genuinely necessary rather
# than cosmetic. The five originally-named properties are seeded FIRST and
# unchanged (booking / isolation / redteam flows discover ids dynamically, but
# keeping these stable is cheap insurance) with their search columns backfilled.
# All prices are EUR cents (the cashier check rejects any other currency).

# AMENITY_POOL is defined in config/initializers/kiosk.rb (loaded at boot) so the
# search_hotels `amenity` enum and these seeds share one closed vocabulary.

# ── The five originals (kept, with search columns backfilled) ────────────────
originals = [
  { name: "Gran Hotel Istanbul", neighbourhood: "Beyoğlu",       stars: 5,
    address: "İstiklal Cd. 12, Beyoğlu, Istanbul",
    amenities: %w[wifi breakfast spa restaurant rooftop_bar],
    rooms: [["Standard", 8000], ["Deluxe", 12000], ["Suite", 20000]] },
  { name: "Kadikoy Suites", neighbourhood: "Kadıköy",            stars: 3,
    address: "Bahariye Cd. 40, Kadıköy, Istanbul",
    amenities: %w[wifi breakfast parking],
    rooms: [["Standard", 6000], ["Deluxe", 9000]] },
  { name: "Sultanahmet Court", neighbourhood: "Sultanahmet",     stars: 4,
    address: "Divanyolu Cd. 5, Sultanahmet, Istanbul",
    amenities: %w[wifi breakfast hammam restaurant],
    rooms: [["Standard", 7000], ["Harbor View", 11000], ["Suite", 18000]] },
  { name: "Bosphorus Palace", neighbourhood: "Beşiktaş",         stars: 5,
    address: "Çırağan Cd. 88, Beşiktaş, Istanbul",
    amenities: %w[wifi breakfast pool spa sea_view airport_shuttle],
    rooms: [["Classic", 15000], ["Bosphorus", 25000]] },
  { name: "Galata House", neighbourhood: "Galata",               stars: 4,
    address: "Galata Kulesi Sk. 3, Galata, Istanbul",
    amenities: %w[wifi breakfast rooftop_bar],
    rooms: [["Standard", 10000], ["Suite", 16000]] },
]

originals.each do |h|
  prop = Property.find_or_create_by!(name: h[:name]) do |p|
    p.city = "Istanbul"
  end
  prop.update!(neighbourhood: h[:neighbourhood], stars: h[:stars],
               amenities: h[:amenities], address: h[:address])
  h[:rooms].each do |rname, cents|
    RoomType.find_or_create_by!(property: prop, name: rname) { |rt| rt.nightly_price_cents = cents }
  end
end

# ── ~95 more coined Istanbul hotels — varied neighbourhood / stars / price ───
# Deterministic (seeded RNG) so a re-seed reproduces the same catalog and the
# pagination proof is stable. Names are coined (no real brands).
rng = Random.new(4242)

neighbourhoods = [
  "Sultanahmet", "Beyoğlu", "Kadıköy", "Beşiktaş", "Şişli", "Fatih",
  "Üsküdar", "Galata", "Taksim", "Ortaköy", "Bakırköy", "Nişantaşı"
].freeze

descriptors = %w[Grand Blue Old City Marmara Golden Pearl Anatolia Levant
                 Meridian Crescent Palm Cedar Ivory Saffron Terrace Garden
                 Harbor Central Boutique Imperial Silk Bosphorus Sunset Amber
                 Mosaic Lantern Tulip Nightingale Serene Vantage].freeze

forms = ["Hotel", "Suites", "Inn", "Residence", "Palace", "House", "Rooms", "Konak"].freeze

room_menus = [
  [["Economy", 4000], ["Standard", 6000]],
  [["Standard", 7000], ["Deluxe", 10500]],
  [["Standard", 9000], ["Deluxe", 13500], ["Suite", 21000]],
  [["Classic", 12000], ["Junior Suite", 18000], ["Grand Suite", 30000]],
  [["Double", 5500], ["Family", 8500]],
].freeze

seen_names = Property.pluck(:name).to_set
target_total = 100

catalog_id = 0
while Property.count < target_total
  catalog_id += 1
  nb   = neighbourhoods.sample(random: rng)
  desc = descriptors.sample(random: rng)
  form = forms.sample(random: rng)
  name = "#{desc} #{nb} #{form}"
  # Ensure uniqueness even if the coined combination repeats.
  name = "#{name} #{catalog_id}" if seen_names.include?(name)
  next if seen_names.include?(name)

  seen_names << name
  stars = rng.rand(2..5)
  amenities = AMENITY_POOL.sample(rng.rand(2..5), random: rng).uniq
  address = "#{desc} Sk. #{rng.rand(1..120)}, #{nb}, Istanbul"

  prop = Property.create!(
    name: name, city: "Istanbul", neighbourhood: nb, stars: stars,
    amenities: amenities, address: address,
  )

  menu = room_menus.sample(random: rng)
  # Nudge nightly price with star rating so higher-star hotels skew pricier —
  # gives the max_price_cents filter something meaningful to bite on.
  bump = (stars - 3) * 1500
  menu.each do |rname, base|
    RoomType.create!(property: prop, name: rname, nightly_price_cents: [base + bump, 2500].max)
  end
end

puts "Seeded: #{Property.count} properties, #{RoomType.count} room types " \
     "across #{Property.distinct.count(:neighbourhood)} neighbourhoods"
