# frozen_string_literal: true

# RLS isolation proof for getgrocery demo:rls.
#
# Run with: KIOSK_RLS_ENFORCE=1 bundle exec rails runner rls_proof.rb
#
# The initializer gate (config/initializers/kiosk.rb) reads KIOSK_RLS_ENFORCE:
#   c.enforce_db_role = true
#   c.app_role        = "kiosk_getgrocery_app"
#
# Kiosk::Server::SessionContext.open then appends
#   SET LOCAL ROLE "kiosk_getgrocery_app"
# after the GUC statements, dropping the session to the non-owner app role
# for the duration of the transaction.
#
# Three-way proof:
#
#   1. Negative control — raw SELECT on the owner/superuser connection WITHOUT
#      SessionContext returns BOTH orders. This is the pre-fix no-op: the login
#      role is a PostgreSQL superuser, which bypasses RLS even with FORCE.
#
#   2. Enforced session for A — SessionContext sets app.current_user_id = A,
#      drops role to kiosk_getgrocery_app (NOBYPASSRLS, non-owner). Raw unscoped
#      SELECT * FROM orders returns ONLY A's row; B's is filtered by the RLS
#      policy (user_id = kiosk.current_user_id()).
#
#   3. Enforced session for B — same but scoped to B; returns only B's row.
#
# NOTE: FORCE is emitted in rls_overlay.rb for production-fidelity (extends the
# guarantee to a non-superuser table owner). In this demo, FORCE does not
# restrict the superuser login role — the effective DB backstop here comes from
# ENABLE + role-drop to kiosk_getgrocery_app (a non-owner, NOSUPERUSER,
# NOBYPASSRLS role).

require "json"

conn = ActiveRecord::Base.connection

# ── Seed two principals and one order each (as owner/superuser) ─────────────
# Fixed UUIDs make the proof idempotent across re-runs within the same schema.
USER_A_ID  = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
USER_B_ID  = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
ORDER_A_ID = "aaa00000-0000-0000-0000-000000000001"
ORDER_B_ID = "bbb00000-0000-0000-0000-000000000001"

[USER_A_ID, USER_B_ID].each do |uid|
  conn.execute(<<~SQL)
    INSERT INTO users (id, created_at, updated_at)
    VALUES ('#{uid}', NOW(), NOW())
    ON CONFLICT (id) DO NOTHING
  SQL
end

[
  [ORDER_A_ID, USER_A_ID, "1 Alpha Ave, Istanbul"],
  [ORDER_B_ID, USER_B_ID, "1 Beta Ave, Istanbul"],
].each do |oid, uid, addr|
  conn.execute(<<~SQL)
    INSERT INTO orders
      (id, user_id, status, total_cents, address, created_at, updated_at)
    VALUES
      ('#{oid}', '#{uid}', 'created', 1599, '#{addr}', NOW(), NOW())
    ON CONFLICT (id) DO NOTHING
  SQL
end

total = conn.execute("SELECT COUNT(*) FROM orders").first["count"].to_i
puts "\nDB: #{total} order(s) total after seed."

# ── Negative control: owner/superuser WITHOUT SessionContext ─────────────────
# The login role (superuser) bypasses RLS: even with FORCE ROW LEVEL SECURITY
# and two policies in place, a superuser sees every row. This is the "no-op"
# state that motivates the role-drop approach.
owner_rows = conn.execute("SELECT id, user_id FROM orders ORDER BY id").to_a
puts "Negative control (owner, no SessionContext): sees #{owner_rows.size} row(s) — expected 2"

# ── Enforced session for A ───────────────────────────────────────────────────
identity_a = Kiosk::Identity.new(user_id: USER_A_ID, role: "customer", actor: "human")
rows_a = nil
Kiosk::Server::SessionContext.open(connection: conn, identity: identity_a) do
  # Inside the transaction: role is kiosk_getgrocery_app, GUC app.current_user_id = A.
  # RLS policy: user_id = kiosk.current_user_id() → filters to A's rows only.
  # This SELECT has NO WHERE clause — the filtering is purely the DB backstop.
  rows_a = conn.execute("SELECT id, user_id FROM orders ORDER BY id").to_a
end
puts "Enforced session A (#{USER_A_ID[0..7]}…): sees #{rows_a.size} row(s) — expected 1"

# ── Enforced session for B ───────────────────────────────────────────────────
identity_b = Kiosk::Identity.new(user_id: USER_B_ID, role: "customer", actor: "human")
rows_b = nil
Kiosk::Server::SessionContext.open(connection: conn, identity: identity_b) do
  rows_b = conn.execute("SELECT id, user_id FROM orders ORDER BY id").to_a
end
puts "Enforced session B (#{USER_B_ID[0..7]}…): sees #{rows_b.size} row(s) — expected 1"

# ── Assertions ───────────────────────────────────────────────────────────────
puts "\n── Assertions ──"
failures = []

if owner_rows.size == 2
  puts "  ✓  negative control: superuser/owner sees #{owner_rows.size} rows — RLS bypassed (no role-drop = no-op)"
else
  failures << "negative control: expected 2 rows, got #{owner_rows.size}"
  puts "  ✗  negative control FAILED: owner sees #{owner_rows.size} (expected 2)"
end

if rows_a.size == 1 && rows_a.first["id"] == ORDER_A_ID
  puts "  ✓  enforced A: sees exactly 1 row (own order #{ORDER_A_ID}) — RLS backstop isolates"
else
  failures << "enforced A: expected [{id: #{ORDER_A_ID}}], got #{rows_a.inspect}"
  puts "  ✗  enforced A FAILED: got #{rows_a.inspect}"
end

if rows_b.size == 1 && rows_b.first["id"] == ORDER_B_ID
  puts "  ✓  enforced B: sees exactly 1 row (own order #{ORDER_B_ID}) — RLS backstop isolates"
else
  failures << "enforced B: expected [{id: #{ORDER_B_ID}}], got #{rows_b.inspect}"
  puts "  ✗  enforced B FAILED: got #{rows_b.inspect}"
end

# ── JSON summary (parsed by rake task assertions) ────────────────────────────
result = {
  "negative_control_owner_sees" => owner_rows.size,
  "enforced_a_sees"             => rows_a&.size,
  "enforced_b_sees"             => rows_b&.size,
  "order_a_id"                  => ORDER_A_ID,
  "order_b_id"                  => ORDER_B_ID,
  "user_a_id"                   => USER_A_ID,
  "user_b_id"                   => USER_B_ID,
  "passed"                      => failures.empty?,
}
puts result.to_json

if failures.empty?
  puts "\nRLS proof PASSED — enforced sessions isolate (DB backstop works); " \
       "owner/superuser without role-drop leaks all rows."
else
  puts "\nRLS proof FAILED:"
  failures.each { |f| puts "  - #{f}" }
  exit 1
end
