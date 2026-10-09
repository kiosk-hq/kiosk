# frozen_string_literal: true

namespace :demo do
  desc "DROP and recreate the demo database, load the schema, seed it. Repeatable, and destructive every time: nothing already in that database survives."
  task :setup do
    # db:schema:load, not db:migrate: the tracked db/schema.rb is the schema's
    # source of truth.
    sh "bundle exec rails db:drop db:create db:schema:load db:seed"
  end
end
