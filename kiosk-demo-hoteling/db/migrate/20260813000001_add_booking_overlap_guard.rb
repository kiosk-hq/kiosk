# frozen_string_literal: true

# The room-night invariant `availability` queries — a room type is offered only
# when NO live booking overlaps the requested nights — needs something behind it
# in the database. Without it `reserve_room` can sell the same room-night twice
# and the operator settles both payments for one physical room.
#
# Postgres can state that invariant directly, which a plain unique index cannot:
# overlap is a RANGE predicate, not equality. An EXCLUDE constraint over
# `daterange(check_in, check_out)` — default half-open `[)`, so a checkout day is
# the next guest's check-in day, exactly the `check_in < other.check_out AND
# check_out > other.check_in` test `availability` runs — scoped to the live
# statuses, so a cancelled/expired booking frees its nights again.
#
# btree_gist is the extension that lets the `=` operator on room_type_id sit in
# the same gist index as the `&&` operator on the range.
#
# NOTE for a database that already carries data: this migration REFUSES to apply
# while any two live bookings overlap (Postgres validates the constraint against
# existing rows) — which is the point, but it means such rows have to be
# reconciled first. The demos rebuild from `db/structure.sql` on every
# `demo:setup`, so there is nothing to reconcile here.
class AddBookingOverlapGuard < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    enable_extension "btree_gist"

    add_exclusion_constraint :bookings,
                             "room_type_id WITH =, daterange(check_in, check_out) WITH &&",
                             using: :gist,
                             where: "status IN ('reserved', 'confirmed')",
                             name: "bookings_no_overlapping_room_nights"
  end
end
