# frozen_string_literal: true

# Kiosk-demo (hoteling-shape) configuration. Hotel booking with payment gate.
# No PoW, no KYC, no hardware unlock.
# Queries: properties, availability, my_bookings
# Actions: reserve_room, confirm_booking

require "securerandom"

require Rails.root.join("lib/stub_idp")
require Rails.root.join("lib/jwt_or_stub_idp")
require Rails.root.join("lib/stub_psp")

# Inject the RLS DSL into ActiveRecord::Migration so that migrations can
# call `enable_rls_on TABLE do ... end` directly.
ActiveRecord::Migration.include(Kiosk::RLS::DSL)

Kiosk.configure do |c|
  c.user_model     = "User"
  c.user_id_type   = :uuid
  c.user_id_column = :id

  c.guc_namespace  = "app"
  c.schema         = "kiosk"

  c.app_role    = ENV.fetch("KIOSK_APP_ROLE",    "app_role")
  c.system_role = ENV.fetch("KIOSK_SYSTEM_ROLE", "app_role")

  c.issuer = ENV.fetch("KIOSK_ISSUER", "http://localhost:3004")
  c.roles  = %i[customer]
  c.owner  = { name: "hoteling", support: "help@hoteling.app" }

  c.agent_idp = JwtOrStubIdp.new(stub: StubIdp.new)

  c.payment_provider = StubPsp.new
end

# ─── Queries ────────────────────────────────────────────────────────────────

Kiosk::Server::Queries.register("properties",
  description: "Browse all available hotel properties") do |_params|
  ActiveRecord::Base.connection.execute(
    "SELECT id, name, city FROM public.properties ORDER BY name"
  ).to_a
end

Kiosk::Server::Queries.register("availability",
  description: "Check room availability at a property for given dates",
  params: {
    property_id: "integer — property to check",
    check_in:    "date string YYYY-MM-DD",
    check_out:   "date string YYYY-MM-DD",
  }) do |params|
  conn = ActiveRecord::Base.connection
  prop_id   = params.fetch(:property_id)  { raise Kiosk::Server::Errors::BadRequest.new("missing field: property_id") }
  check_in  = params.fetch(:check_in)     { raise Kiosk::Server::Errors::BadRequest.new("missing field: check_in") }
  check_out = params.fetch(:check_out)    { raise Kiosk::Server::Errors::BadRequest.new("missing field: check_out") }
  conn.execute(<<~SQL).to_a
    SELECT rt.id, rt.name, rt.nightly_price_cents
    FROM public.room_types rt
    WHERE rt.property_id = #{conn.quote(prop_id.to_s)}::integer
    AND rt.id NOT IN (
      SELECT room_type_id FROM public.bookings
      WHERE property_id = #{conn.quote(prop_id.to_s)}::integer
        AND status IN ('reserved', 'confirmed')
        AND check_in < #{conn.quote(check_out.to_s)}::date
        AND check_out > #{conn.quote(check_in.to_s)}::date
    )
    ORDER BY rt.nightly_price_cents
  SQL
end

Kiosk::Server::Queries.register("my_bookings",
  description: "List this principal's hotel bookings (scoped to authenticated user)") do |_params|
  ActiveRecord::Base.connection.execute(
    "SELECT b.id, b.property_id, b.room_type_id, b.check_in, b.check_out, b.total_cents, b.status " \
    "FROM public.bookings b " \
    "WHERE b.user_id = kiosk.current_user_id() " \
    "ORDER BY b.created_at DESC"
  ).to_a
end

# ─── Actions ────────────────────────────────────────────────────────────────

Kiosk::Server::Actions.register("reserve_room",
  description: "Reserve a room for the authenticated principal (creates a TTL hold)",
  params: {
    property_id:  "integer — property id",
    room_type_id: "integer — room type id",
    check_in:     "date string YYYY-MM-DD",
    check_out:    "date string YYYY-MM-DD",
  }) do |args|
  conn = ActiveRecord::Base.connection
  uid = conn.execute("SELECT kiosk.current_user_id() AS uid").first["uid"]
  raise Kiosk::Server::Errors::Unauthenticated.new("no authenticated user") if uid.nil?
  agent_id = conn.execute("SELECT kiosk.current_agent_id() AS aid").first["aid"]

  property_id  = args.fetch(:property_id)  { raise Kiosk::Server::Errors::BadRequest.new("missing field: property_id") }
  room_type_id = args.fetch(:room_type_id) { raise Kiosk::Server::Errors::BadRequest.new("missing field: room_type_id") }
  check_in     = args.fetch(:check_in)     { raise Kiosk::Server::Errors::BadRequest.new("missing field: check_in") }
  check_out    = args.fetch(:check_out)    { raise Kiosk::Server::Errors::BadRequest.new("missing field: check_out") }

  # Validate room_type belongs to property
  rt = conn.execute(
    "SELECT id, name, nightly_price_cents FROM public.room_types " \
    "WHERE id = #{conn.quote(room_type_id.to_s)}::integer " \
    "AND property_id = #{conn.quote(property_id.to_s)}::integer LIMIT 1"
  ).first
  raise Kiosk::Server::Errors::BadRequest.new("room type not found for this property") if rt.nil?

  # Calculate total_cents (nights × nightly_price_cents)
  ci  = Date.parse(check_in.to_s)
  co  = Date.parse(check_out.to_s)
  raise Kiosk::Server::Errors::BadRequest.new("check_out must be after check_in") unless co > ci
  nights      = (co - ci).to_i
  total_cents = nights * rt["nightly_price_cents"].to_i

  # INSERT booking row
  booking = conn.execute(<<~SQL).first
    INSERT INTO public.bookings (user_id, property_id, room_type_id, check_in, check_out, total_cents, status, created_at, updated_at)
    VALUES (
      #{conn.quote(uid)}::uuid,
      #{conn.quote(property_id.to_s)}::integer,
      #{conn.quote(room_type_id.to_s)}::integer,
      #{conn.quote(check_in.to_s)}::date,
      #{conn.quote(check_out.to_s)}::date,
      #{conn.quote(total_cents.to_s)}::integer,
      'reserved',
      now(), now()
    )
    RETURNING id
  SQL

  booking_id = booking["id"]

  # INSERT kiosk.reservations TTL row bound to the booking
  conn.execute(<<~SQL)
    INSERT INTO kiosk.reservations (user_id, agent_id, resource_kind, resource_id, args, expires_at)
    VALUES (
      #{conn.quote(uid)}::uuid,
      #{agent_id.nil? ? "NULL" : "#{conn.quote(agent_id.to_s)}::uuid"},
      'room_booking',
      #{conn.quote(booking_id.to_s)},
      '{}'::jsonb,
      now() + interval '15 minutes'
    )
  SQL

  {
    booking_id:  booking_id,
    total_cents: total_cents,
  }
end

Kiosk::Server::Actions.register("confirm_booking",
  description: "Confirm a reserved booking (requires payment mandate referencing this booking)",
  params: {
    booking_id: "uuid — the booking to confirm",
  }) do |args|
  conn = ActiveRecord::Base.connection

  booking_id = args[:booking_id]
  if booking_id.nil? || booking_id.to_s.empty?
    raise Kiosk::Server::Errors::BadRequest.new("missing field: booking_id")
  end

  # ── Gate 1: booking belongs to principal AND status = 'reserved' ──────
  booking = conn.execute(
    "SELECT id FROM public.bookings " \
    "WHERE id = #{conn.quote(booking_id.to_s)}::uuid " \
    "AND user_id = kiosk.current_user_id() " \
    "AND status = 'reserved' " \
    "LIMIT 1"
  ).first
  raise Kiosk::Server::Errors::Forbidden.new("booking not found or not yours") if booking.nil?

  # ── Gate 2: settled payment mandate whose cart references THIS booking ─
  booking_filter_json = [{ booking_id: booking_id.to_s }].to_json
  paid = conn.execute(
    "SELECT 1 AS ok " \
    "FROM kiosk.payment_mandates pm " \
    "JOIN kiosk.cart_mandates cm ON cm.id = pm.cart_mandate_id " \
    "WHERE pm.user_id = kiosk.current_user_id() " \
    "AND cm.line_items @> #{conn.quote(booking_filter_json)}::jsonb " \
    "LIMIT 1"
  ).first
  raise Kiosk::Server::Errors::Forbidden.new("no settled payment mandate for this booking") if paid.nil?

  # ── All gates passed: confirm ─────────────────────────────────────────
  confirmation_code = SecureRandom.uuid
  conn.execute(
    "UPDATE public.bookings SET status = 'confirmed', updated_at = now() " \
    "WHERE id = #{conn.quote(booking_id.to_s)}::uuid"
  )

  {
    booking_id:        booking_id,
    status:            "confirmed",
    confirmation_code: confirmation_code,
  }
end
