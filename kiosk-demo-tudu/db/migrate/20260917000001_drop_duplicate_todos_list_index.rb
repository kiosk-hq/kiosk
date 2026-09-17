# frozen_string_literal: true

# todos(list_id) was indexed TWICE — delivering the removal to the databases
# that already carry both.
#
# `create_table :todos` declares `t.references :list`, which builds
# `index_todos_on_list_id`; migration 20260719000001 then added
# `add_index :todos, :list_id, name: "index_todos_on_list", if_not_exists: true`
# beside it. That guard READS like it prevents exactly this and does not: Rails
# keys `if_not_exists:` on the index NAME, and the name was a new one, so the
# second CREATE INDEX fired every time. The result is two btree indexes over one
# column, identical apart from their names — a second write on every INSERT and
# UPDATE of a todo, serving no read the first cannot — and `db/structure.sql`
# publishes both to every operator who copies this schema.
#
# THE `t.references` INDEX IS THE ONE THAT STAYS: it is the name Rails gives by
# convention, which is the one a reader (and `remove_index :todos, :list_id`)
# expects to find.
#
# WHY A NEW FILE AND NOT A DELETED LINE. 20260719000001 is recorded in the
# `schema_migrations` of every deployed database, so `db:migrate` never runs it
# again; editing it would reach `db/structure.sql` and every from-zero database
# and no running one — the failure mode that has already served HTTP 500s from a
# live demo box while every gate stayed green.
#
# GUARDED with `if_exists:`, because a database built from a structure.sql dumped
# after this lands never had the duplicate, and an error there would strand every
# migration behind it.
class DropDuplicateTodosListIndex < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def up
    remove_index :todos, name: "index_todos_on_list", if_exists: true
  end

  # Restores the duplicate, so a rollback lands on the schema that shipped.
  def down
    add_index :todos, :list_id, name: "index_todos_on_list", if_not_exists: true
  end
end
