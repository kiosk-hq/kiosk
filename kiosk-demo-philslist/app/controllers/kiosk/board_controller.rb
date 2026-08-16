# frozen_string_literal: true

# philslist's READ surface: the two verbs an assistant reaches with
# `POST /kiosk/query`. Kiosk ships a MIXIN, not a base class — the superclass is
# this app's own ApplicationController, and `include Kiosk::Query` is the whole
# contract. Each class-level macro records a declaration and the NEXT `def`
# claims it, so a method with no macros above it is a helper the wire cannot see.
#
# A controller declares queries OR actions, never both — the verb it is reached
# by is a property of the class — so the write half lives next door in
# Kiosk::ListingsController.
#
# NOT ROUTABLE. config/routes.rb draws nothing at this controller: handlers are
# reached only through the wire, which is where authentication, the registration
# PoW gate and the GUC-scoped transaction live. A route drawn straight here
# would bypass all three, and the mixin answers such a request 404.
class Kiosk::BoardController < ApplicationController
  include Kiosk::Query

  # browse_listings — the OPEN board. Any authenticated principal sees ALL
  # matching listings across ALL owners (no owner_id filter). Optional
  # category_slug + keyword filters; status clamps to open|closed (defaults
  # open). All caller input is passed through conn.quote (parameterized ILIKE on
  # title/body) — no raw interpolation (raw-pipe hygiene, the sibling-demo
  # quoting pattern).
  description "Browse the public classifieds board across all sellers. Optional " \
              "category_slug and keyword filters; status defaults to open. All " \
              "filters are optional and AND together; each row carries a " \
              "`listing_id` (pass it to edit_listing / close_listing as `listing_id`), " \
              "title, body, free-form price_text, category_slug, status, and " \
              "owner_handle. Returns all matching listings (small board; not " \
              "paginated); prices are free-form text (e.g. \"€300\"), not cents."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 category_slug: { type: "string",
                                  enum: %w[furniture bikes electronics housing free],
                                  description: "Restrict to one category." },
                 keyword:       { type: "string", description: "Case-insensitive match on title or body." },
                 status:        { type: "string", enum: %w[open closed], default: "open",
                                  description: "Listing status filter." },
               },
               required: []
  example_params({ category_slug: "bikes", keyword: "road", status: "open" })
  example_row({
    listing_id: "9c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5f", title: "Carbon road bike — €300",
    body: "Lightweight carbon road bike, 54cm, Shimano 105 groupset.",
    price_text: "€300", category_slug: "bikes", status: "open",
    owner_handle: "alice@example.com",
  })
  def browse_listings
    conn = ActiveRecord::Base.connection

    status = params[:status].to_s
    status = "open" unless Listing::STATUSES.include?(status)

    sql = +<<~SQL
      SELECT l.id AS listing_id, l.title, l.body, l.price_text, c.slug AS category_slug,
             l.status, u.email AS owner_handle
        FROM listings l
        JOIN categories c ON c.id = l.category_id
        JOIN users u ON u.id = l.owner_id
       WHERE l.status = #{conn.quote(status)}
    SQL

    sql << " AND c.slug = #{conn.quote(params[:category_slug].to_s)}" if params[:category_slug].present?
    if params[:keyword].present?
      like = conn.quote("%#{params[:keyword]}%")
      sql << " AND (l.title ILIKE #{like} OR l.body ILIKE #{like})"
    end
    sql << " ORDER BY l.created_at DESC, l.id"

    render json: conn.execute(sql).to_a
  end

  # my_listings — per-identity: the caller's OWN listings only. Caller supplies
  # no filter; the WHERE is provider-controlled and un-bypassable (the saas
  # my_appointments pattern).
  description "List the listings owned by the authenticated principal " \
              "(scoped to kiosk.current_user_id())."
  # A verb that takes nothing still declares the empty closed object, so "this
  # verb takes no arguments" is a published fact rather than an absence an
  # assistant has to interpret.
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  def my_listings
    render json: ActiveRecord::Base.connection.execute(
      "SELECT l.id AS listing_id, l.title, l.price_text, l.status, c.slug AS category_slug " \
      "FROM listings l JOIN categories c ON c.id = l.category_id " \
      "WHERE l.owner_id = kiosk.current_user_id() " \
      "ORDER BY l.created_at DESC, l.id",
    ).to_a
  end
end
