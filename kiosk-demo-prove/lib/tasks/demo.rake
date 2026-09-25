# frozen_string_literal: true

# kiosk-demo-prove (the KYC broker) demo orchestration. This app is an ISSUER, not a
# Kiosk operator, so it has NO wire/rideflow/redteam of its own — its behavior
# is exercised (a) by its rspec suite and (b) by skooti's two-server check:kyc
# (which boots this broker and drives the full cross-app flow). These tasks are
# the minimal setup + test entrypoints CI calls.
#
#   rake demo:setup  idempotent db drop/create/schema:load/seed
#   rake check:test   the broker's own rspec suite (DB-backed)

namespace :demo do
  desc "DROP and recreate the KYC broker database, load the schema, seed it. Repeatable, and destructive every time: nothing already in that database survives."
  task :setup do
    sh "bundle exec rails db:drop db:create db:schema:load db:seed"
  end
end

namespace :check do

  desc "Run the broker's own rspec suite (security model: intake, binding, single-use, TTL, SSRF guard)."
  task :test do
    sh "RAILS_ENV=test bundle exec rails db:drop db:create db:schema:load"
    sh "bundle exec rspec"
  end
end

