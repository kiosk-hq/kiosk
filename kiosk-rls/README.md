# kiosk-rls

Optional DB-layer defense-in-depth for [Kiosk](https://kiosk.tech) providers.

## Security model overview

**RLS is not Kiosk's primary security model.** Kiosk's isolation comes from the sanctioned `query`/`run`/`pay` surface: agents never send raw SQL, named queries enforce app-layer authz, and `kiosk.current_user_id()` GUCs scope per-user reads in Ruby. That surface is sufficient.

`kiosk-rls` is an **optional** companion for providers who want an additional DB-level row enforcement layer — belt-and-suspenders hardening. Calling `enable_rls_on` is opt-in; not calling it is the default and fully correct.

## What it does

`kiosk-rls` provides the Ruby DSL providers use inside their ActiveRecord migrations to declare RLS policies — and compiles those declarations to standard PostgreSQL DDL.

When you opt in, `enable_rls_on` emits both `ENABLE ROW LEVEL SECURITY` **and** `FORCE ROW LEVEL SECURITY` so the policies actually enforce. Without `FORCE`, Postgres exempts the table owner from RLS — making it a no-op for the typical Rails setup where the app connects as the owner.

**Prerequisite for real enforcement:** the application must connect as a **non-superuser, non-owner role** (the `app_role`) with table GRANTs. `FORCE` makes RLS apply to the table owner too, but a Postgres superuser still bypasses all policies unconditionally. Never use a superuser as the runtime role when RLS enforcement matters.

```ruby
# db/migrate/20260101000002_create_rentals.rb
class CreateRentals < ActiveRecord::Migration[8.1]
  def change
    create_table :rentals do |t|
      t.references :user,    null: false, foreign_key: true
      t.references :scooter, null: false, foreign_key: true
      t.timestamp  :started_at, null: false
      t.timestamp  :ended_at
      t.integer    :total_cents
      t.timestamps
    end

    enable_rls_on :rentals do
      policy :select, using: "user_id = kiosk.current_user_id()"
      policy :insert, check: "user_id = kiosk.current_user_id() AND kiosk.current_role() = 'customer'"
      comment "Scooter rentals owned by the renting user. Mutations after creation go through Actions."
    end
  end
end
```

Compiles to:

```sql
ALTER TABLE "rentals" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "rentals" FORCE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON "rentals" TO "app_role";
CREATE POLICY "rentals_select" ON "rentals" FOR SELECT USING (user_id = kiosk.current_user_id());
CREATE POLICY "rentals_insert" ON "rentals" FOR INSERT WITH CHECK (user_id = kiosk.current_user_id() AND kiosk.current_role() = 'customer');
COMMENT ON TABLE "rentals" IS 'Scooter rentals owned by the renting user. ...';
```

## Evolving policies

```ruby
add_kiosk_policy_to    :rentals, :select, using: "..."
change_kiosk_policy_on :rentals, :update, using: "...", check: "..."
remove_kiosk_policy_from :rentals, :delete
rename_kiosk_policy_on   :rentals, from: :select, to: "rentals_select_owner_or_admin"
```

## Install

```ruby
gem "kiosk-rls"
```

Or, via the meta-gem:

```ruby
gem "kiosk-all"
```

## Rails integration

For now, opt-in manually in `config/initializers/kiosk_rls.rb`:

```ruby
require "kiosk/rls"
ActiveRecord::Migration.include(Kiosk::RLS::DSL)
```

A `kiosk/rls/migration` auto-inject path lands later.

## Status

Pre-v0.1 alpha. The DSL surface is stable across pre-v0.1 minor bumps; SQL emission may evolve as we add corner cases (schema-qualified tables, partitioned tables, view-based column gating per spec §7.8).

Out of this release: `rake kiosk:rls:show TABLE` and `rake kiosk:rls:check` (need a live PostgreSQL connection and land in a follow-up).

## License

Apache-2.0 — see `LICENSE.txt`.

## Links

- [kiosk.tech](https://kiosk.tech)
- [Design spec §7](https://github.com/kiosk-hq/kiosk-meta) (private during pre-launch)
- [Issue tracker](https://github.com/kiosk-hq/kiosk/issues)
