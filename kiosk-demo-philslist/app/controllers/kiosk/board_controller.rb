# frozen_string_literal: true

# philslist's READ surface: the two verbs an assistant reaches with
# `GET /kiosk/<query-name>`, one endpoint per verb, arguments in the query
# string. Kiosk ships a MIXIN, not a base class — the superclass is
# this app's own ApplicationController, and `include Kiosk::Handler` is the whole
# contract. Each class-level macro records a declaration and the NEXT `def`
# claims it, so a method with no macros above it is a helper the wire cannot see.
#
# `kind :query` above each declaration is what puts it on `GET`; the kind
# belongs to the DECLARATION, not to the class (K-921), so ONE controller may
# declare both. Keeping the read and the write halves in separate classes is
# this demo's shape, not a rule. The write half lives next door in
# Kiosk::ListingsController.
#
# NOT ROUTABLE. config/routes.rb draws nothing at this controller: handlers are
# reached only through the wire, which is where authentication, the registration
# PoW gate and the GUC-scoped transaction live. A route drawn straight here
# would bypass all three, and the mixin answers such a request 404.
class Kiosk::BoardController < ApplicationController
  include Kiosk::Handler

  # browse_listings — the OPEN board. Any authenticated principal sees ALL
  # matching listings across ALL owners (no owner_id filter). Two optional
  # filters, `category_slug` and `keyword`.
  #
  # THERE IS NO `status` FILTER, and its absence is a decision (Phil,
  # 2026-08-21): «Это из метода `def browse_listings` … В первом он не нужен, и
  # даже вреден.» This verb IS the open board — a closed listing is off it —
  # so a caller-facing status knob could only ever ask for something the board
  # does not serve. "Did my listing sell?" is `my_listings`, a different verb
  # with an owner-scoped contract, and if it ever needs the filter it declares
  # its own.
  #
  # EVERY CALLER VALUE IS ADAPTER-QUOTED BEFORE IT REACHES THE SQL TEXT, and
  # that is the honest version of the sentence that used to stand here (K-915).
  # It claimed no caller value is ever "spliced into SQL"; the value IS spliced
  # — Arel's `matches` visitor inlines an adapter-quoted literal and `binds` is
  # empty, because Rails 8.1 disables prepared statements by default. What is
  # true is that nothing here builds SQL by hand: the filters are ordinary
  # ActiveRecord conditions, the keyword search is an Arel node, and the
  # quoting is the adapter's job (K-654). The one thing quoting does NOT do is
  # neutralise LIKE metacharacters, which is why the keyword is passed through
  # `sanitize_sql_like` below (K-914).
  #
  # ADR-0023: semantics only. The filters and their domains are declared in
  # `input_schema`; the row's fields, and that a price is free-form display
  # text rather than an amount, are declared in `output_schema`. What is left
  # here is what neither can say: what the board IS and what an empty answer
  # means.
  # `reach :published` — THE BOARD IS THE DEPARTURE, AND NOW IT SAYS SO (K-949,
  # ADR-0028). Spec §7.2's default is absolute: a verb touches only the calling
  # principal's rows. This one touches every seller's, because an open
  # classifieds board that showed you only your own listings would not be a
  # board. Before ADR-0028 that was a silent contradiction of the strongest
  # sentence in the spec; the declaration makes it a published claim an
  # assistant, an auditor and `demo:isolation` can all read off the wire. It is
  # `published` rather than `consented` because nobody consented to anything —
  # philslist publishes these rows by its own decision, which is the weaker of
  # the two sharing claims and the one that costs the most: §7.2 forbids an
  # account's login identifier anywhere in a published row, which is the rule
  # K-913 is made of and why `owner_handle` is a pseudonym.
  kind :query
  reach :published
  description "Browse the public classifieds board across ALL sellers — this is the open board, not " \
              "the caller's own corner of it. Every filter is optional and they AND together, and a " \
              "filter value this board cannot serve is refused 400 naming what it will accept, never " \
              "silently reinterpreted — so an EMPTY array means nothing matched, not that the query " \
              "was misunderstood. Returns all matching listings rather than a page of them (small " \
              "board; not paginated). Sellers are named by an opaque, stable pseudonym, never by an " \
              "address — this operator brokers no messages, so the only way to reach a seller is the " \
              "contact details they chose to publish in the listing text. Once the human picks a row, " \
              "`edit_listing` and `close_listing` act on it, and both are owner-only."
  # `category_slug`'s domain IS THE `categories` TABLE, so it is declared as a
  # PROC rather than a literal list (K-922, Phil 2026-08-21). An operator who
  # adds a section gets a schema that accepts it — and a 400 that names it —
  # without a restart and without a deploy: the engine calls the proc when the
  # catalog is served, memoizes it for a minute, and the `?v=` version on
  # `schema_url` moves with it. Writing `Category.pluck(:slug)` here instead
  # would run at class-body load, which is `db:create` and `db:migrate` too.
  # Ordered, so the published enum is byte-stable across boots.
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 category_slug: { type: "string",
                                  enum: -> { Category.order(:slug).pluck(:slug) },
                                  description: "Restrict to one category." },
                 keyword:       { type: "string", description: "Case-insensitive match on title or body." },
               },
               required: []
  output_schema type: "array",
                description: "Matching listings across all sellers, newest first.",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    listing_id:    { type: "string", description: "uuid. Pass to edit_listing / close_listing as `listing_id`." },
                    title:         { type: "string", description: "The seller's headline." },
                    body:          { type: "string", description: "The listing description." },
                    price_text:    { type: %w[string null], description: "FREE-FORM display text, e.g. \"€300\" or \"Free\" — never a cents amount, and null when the seller gave none." },
                    category_slug: { type: "string", description: "The section it is posted in." },
                    status:        { type: "string", description: "Always `open` on this verb — the board carries open listings only." },
                    # NEVER NULL SINCE K-913, and the nullability went away with
                    # the leak rather than being separately fixed. This column
                    # used to be `users.email`, which is nullable — a
                    # PoW-registered assistant's account has none — so the
                    # schema said `%w[string null]` and every listing posted
                    # through `demo:register` published a null seller. It is now
                    # {User.public_handle}, derived from the account UUID, and
                    # an account without a UUID cannot own a row: the type is
                    # `string`, flatly, and an assistant no longer has to
                    # branch on a null it could do nothing with.
                    owner_handle:  { type: "string", description: "The seller's PSEUDONYM on this board — stable for one account (so two rows sharing it are the same seller), opaque, and NOT an address: it is derived from the account id and reveals no email, phone or login. There is no verb that turns it back into a person. To reach a seller, use the contact details they chose to put in `body`; a listing with none names no way to contact its seller." },
                  },
                  required: %w[listing_id title body price_text category_slug status owner_handle],
                }
  example_params({ category_slug: "bikes", keyword: "road" })
  example_row({
    listing_id: "9c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5f", title: "Carbon road bike — €300",
    body: "Lightweight carbon road bike, 54cm, Shimano 105 groupset.",
    price_text: "€300", category_slug: "bikes", status: "open",
    owner_handle: "seller-4f2a9c1e3b7d",
  })
  def browse_listings
    # OPEN IS NOT A DEFAULT, IT IS THE BOARD. There is no `status` parameter to
    # honour (see the note above the declaration), so the scope is the
    # provider's, not the caller's — the same shape as `my_listings`' owner
    # scope, one line up the stack.
    #
    # T-090's lesson survives the removal and now applies to `category_slug`:
    # a filter value outside its domain must be REFUSED, never quietly
    # reinterpreted. This method contains no clamp for exactly that reason —
    # `category_slug` declares its enum and `input_schema` is validated on
    # every per-verb call (spec §8.1 item 5), so an unknown section is answered
    # `400 bad_request` naming the live ones before the handler runs.
    board = Listing.joins(:category, :owner)
                   .where(status: "open")
                   .order(created_at: :desc, id: :asc)
    board = board.where(categories: { slug: params[:category_slug].to_s }) if params[:category_slug].present?
    if params[:keyword].present?
      # `sanitize_sql_like` FIRST, and the surrounding `%` after it (K-914).
      # Adapter quoting keeps the value inside the literal — this is not an
      # injection surface — but it does nothing about LIKE's own
      # metacharacters, so an unescaped `_` was a live single-character
      # wildcard and an unescaped `%` a live multi-character one. A human
      # searching for "50% off" got every listing whose title started "50"
      # instead: a different question, answered confidently, which is the same
      # failure mode T-090 removed from the status filter.
      pattern = "%#{Listing.sanitize_sql_like(params[:keyword])}%"
      board = board.where(
        Listing.arel_table[:title].matches(pattern).or(Listing.arel_table[:body].matches(pattern)),
      )
    end

    # `pluck` rather than loading models: this is a projection, and naming the
    # columns is what keeps the wire's field names and their order a decision
    # this handler makes rather than a side effect of the schema. One query, no
    # N+1 — the joins above already carry the category slug and the owner id.
    #
    # `users.id`, NEVER `users.email` (K-913). This projection is the whole
    # exposure: the board is cross-owner by design, so whatever stands in this
    # column is published to every principal that can authenticate, for every
    # account that has ever posted. It used to be the login address. The id it
    # plucks instead does not leave this method either — {User.public_handle}
    # turns it into the board pseudonym before the row is built, so no internal
    # identifier reaches the wire in its place. The join stays: it is what
    # proves the owner row exists, and a listing whose owner vanished should
    # fall off the board rather than render a handle for nobody.
    render json: board.pluck(
      "listings.id", "listings.title", "listings.body", "listings.price_text",
      "categories.slug", "listings.status", "users.id",
    ).map { |id, title, body, price_text, category_slug, row_status, owner_id|
      { listing_id: id, title: title, body: body, price_text: price_text,
        category_slug: category_slug, status: row_status,
        owner_handle: User.public_handle(owner_id) }
    }
  end

  # my_listings — per-identity: the caller's OWN listings only. Caller supplies
  # no filter; the scope is provider-controlled and un-bypassable (the saas
  # my_appointments pattern). `owned_by_current_principal` is the ONE place the
  # identity predicate is written — see Listing for why it stays SQL-side.
  kind :query
  description "List the listings owned by the authenticated principal " \
              "(scoped to kiosk.current_user_id())."
  # A verb that takes nothing still declares the empty closed object, so "this
  # verb takes no arguments" is a published fact rather than an absence an
  # assistant has to interpret.
  input_schema type: "object", additionalProperties: false, properties: {}, required: []
  # NARROWER than a browse_listings row on purpose: an owner reading their own
  # board does not need the body or their own handle back, so this projection
  # is four fields rather than seven and the schema is where an assistant reads
  # that difference instead of discovering it.
  output_schema type: "array",
                description: "The principal's own listings, newest first.",
                items: {
                  type: "object", additionalProperties: false,
                  properties: {
                    listing_id:    { type: "string", description: "uuid. Pass to edit_listing / close_listing as `listing_id`." },
                    title:         { type: "string", description: "The headline." },
                    price_text:    { type: %w[string null], description: "FREE-FORM display text, never a cents amount; null when none was given." },
                    status:        { type: "string", description: "open | closed." },
                    category_slug: { type: "string", description: "The section it is posted in." },
                  },
                  required: %w[listing_id title price_text status category_slug],
                }
  def my_listings
    render json: Listing.owned_by_current_principal
                        .joins(:category)
                        .order(created_at: :desc, id: :asc)
                        .pluck("listings.id", "listings.title", "listings.price_text",
                               "listings.status", "categories.slug")
                        .map { |id, title, price_text, row_status, category_slug|
                          { listing_id: id, title: title, price_text: price_text,
                            status: row_status, category_slug: category_slug }
                        }
  end
end
