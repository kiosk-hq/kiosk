# frozen_string_literal: true

# ── A TODO'S TIME IS THE READER'S, SO IT IS STORED AS AN INSTANT ────────────
#
# "Tomorrow at two" is said by one person and read by another. Share the list
# and the second reader is in another city, so there is NO single wall-clock
# string that is correct for both of them -- which is exactly why the stored
# value is an absolute instant and every rendering is relative to whoever is
# reading. A `timestamp with time zone` column is what makes that true in the
# schema rather than in a convention: the value is the moment, and the wall
# clock is computed per reader.
#
# NULLABLE, because most todos have no deadline. A todo with no `due_at` is a
# todo with no deadline, not a todo due at some default.
class AddDueAtToTodos < ActiveRecord::Migration[8.1]
  def change
    add_column :todos, :due_at, :timestamptz
  end
end
