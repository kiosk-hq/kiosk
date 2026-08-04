# frozen_string_literal: true

# prove.my (kiosk-demo-prove) demo orchestration. This app is an ISSUER, not a
# Kiosk operator, so it has NO wire/rideflow/redteam of its own — its behavior
# is exercised (a) by its rspec suite and (b) by skooti's two-server demo:kyc
# (which boots this broker and drives the full cross-app flow). These tasks are
# the minimal setup + test entrypoints CI calls.
#
#   rake demo:setup  idempotent db drop/create/schema:load/seed
#   rake demo:test   the broker's own rspec suite (DB-backed)
#   rake demo        setup + test

namespace :demo do
  desc "Create + load schema + seed the prove.my broker database (idempotent)."
  task :setup do
    sh "bundle exec rails db:drop db:create db:schema:load db:seed"
  end

  desc "Run the broker's own rspec suite (security model: intake, binding, single-use, TTL, SSRF guard)."
  task :test do
    sh "RAILS_ENV=test bundle exec rails db:drop db:create db:schema:load"
    sh "bundle exec rspec"
  end
end

desc "prove.my broker: set up the DB then run its rspec suite."
task demo: ["demo:setup", "demo:test"]
