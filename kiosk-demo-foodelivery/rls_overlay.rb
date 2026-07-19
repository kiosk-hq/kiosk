# frozen_string_literal: true

# RLS overlay setup for foodelivery demo:rls.
#
# Run as the privileged owner connection BEFORE rls_proof.rb.
# Does NOT add a Rails migration — this is an imperative overlay layered on top
# of the structure.sql-loaded schema.  structure.sql is intentionally left with
# NO ROW LEVEL SECURITY so the default Path-C demo:order path stays clean.
#
# Called by: rake demo:rls (no KIOSK_RLS_ENFORCE — setup runs as owner)
#
# Dogfoods Kiosk::RLS::Emitter, which emits the canonical sequence:
#   ALTER TABLE orders ENABLE ROW LEVEL SECURITY
#   ALTER TABLE orders FORCE ROW LEVEL SECURITY        ← production-fidelity: applies to table owner
#   GRANT SELECT, INSERT, UPDATE, DELETE ON orders TO kiosk_foodelivery_app
#   CREATE POLICY orders_select ON orders FOR SELECT USING (user_id = kiosk.current_user_id())
#   CREATE POLICY orders_insert ON orders FOR INSERT WITH CHECK (user_id = kiosk.current_user_id())
#   COMMENT ON TABLE orders IS '...'
#
# NOTE: FORCE extends the RLS guarantee to the table owner (a non-superuser role
# in production). In this demo the login role is a PostgreSQL superuser, so the
# superuser always bypasses row security — FORCE alone cannot restrict it.
# The effective backstop here is the combination of ENABLE + non-owner role-drop
# (SET LOCAL ROLE kiosk_foodelivery_app inside SessionContext).  FORCE is
# emitted so the overlay is production-identical.

conn = ActiveRecord::Base.connection

# ── Schema USAGE ─────────────────────────────────────────────────────────────
# public schema: PUBLIC already has USAGE (ACL: =U/pg_database_owner) but
# granting explicitly makes the permissions model self-documenting.
# kiosk schema: ACL is NULL (default) — only the owner has access.
# kiosk_foodelivery_app must have USAGE to call kiosk.current_user_id() from
# within RLS policy expressions.
conn.execute("GRANT USAGE ON SCHEMA public TO kiosk_foodelivery_app")
conn.execute("GRANT USAGE ON SCHEMA kiosk TO kiosk_foodelivery_app")
puts "  GRANT USAGE ON SCHEMA public, kiosk TO kiosk_foodelivery_app"

# ── RLS on orders via kiosk-rls Emitter (dogfooded) ─────────────────────────
# orders.id is uuid (gen_random_uuid()), no integer sequence — sequences: [].
table = Kiosk::RLS::Table.new(
  :orders,
  app_role:  "kiosk_foodelivery_app",
  sequences: [],
)
table.instance_eval do
  policy :select, using: "user_id = kiosk.current_user_id()"
  policy :insert, check: "user_id = kiosk.current_user_id()"
  comment "Orders owned by the placing user — RLS DB backstop (foodelivery demo:rls, R1 T5)."
end
table.validate!

stmts = Kiosk::RLS::Emitter.statements_for(table)
stmts.each { |sql| conn.execute(sql) }

puts "  RLS overlay: #{stmts.size} statements applied:"
stmts.each { |s| puts "    #{s}" }
