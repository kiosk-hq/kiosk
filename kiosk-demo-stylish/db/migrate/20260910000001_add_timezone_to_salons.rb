# frozen_string_literal: true

# ── THE CHAIR'S CLOCK IS THE SALON'S, AND NOW IT IS RECORDED ────────────────
#
# stylish renders its service AT THE SALON: a chair, at an address, at an hour.
# The clock was named once, on the ORIGIN, with the reasoning that «a per-salon
# column is a different demo from this one» -- true of a demo that seeds one
# salon, and false of the rule, which is that the zone belongs to the thing
# being SERVED. One operator may run salons in more than one city, and an
# answer read off the origin is right only for as long as it does not.
#
# WHY A COLUMN AND NOT A DERIVATION. `salons` is (id, name, created_at,
# updated_at): there is nothing here to derive a zone FROM, and inferring one
# from a name would be exactly the guess the rule forbids. The column is the
# only source that cannot be wrong.
#
# WHY THE DEFAULT STAYS ON THE COLUMN. It is the ORIGIN's default zone, and its
# job is to FILL this column rather than to answer a request: the seeded salon
# backfills to it, and a salon added without a zone is declared to be in Paris
# rather than being in no zone at all. `NOT NULL` is what stops the "resource
# with no zone" case from ever arising.
class AddTimezoneToSalons < ActiveRecord::Migration[8.1]
  def change
    add_column :salons, :timezone, :string, null: false, default: "Europe/Paris"
  end
end
