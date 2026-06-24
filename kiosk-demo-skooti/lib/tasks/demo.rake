# frozen_string_literal: true

# Kiosk demo orchestration for kiosk-demo-skooti. Tasks:
#
#   rake demo:setup        idempotent db:drop / create / migrate / seed
#   rake demo:walkthrough  boots the server, runs a curl-driven showcase, tears down
#   rake demo              setup (the B1/B2 scaffolding proof)
#
# The full unlock-chain proof (register → KYC → reserve → pay → unlock → lock-sim)
# is Task B4 (unlock_flow.rb) and is NOT part of this rake file.

namespace :demo do
  desc "Create + migrate + seed the demo database (idempotent)."
  task :setup do
    sh "psql -d postgres -tAc \"DO \\$\\$ BEGIN " \
       "IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_role') " \
       "THEN CREATE ROLE app_role NOLOGIN; END IF; END \\$\\$;\" >/dev/null"
    sh "psql -d postgres -tAc 'GRANT app_role TO CURRENT_USER' >/dev/null"
    sh "bundle exec rails db:drop db:create db:migrate db:seed"
  end

  desc "Boot the server and run the curl demo walkthrough."
  task :walkthrough do
    exec File.expand_path("../../bin/demo", __dir__)
  end
end

desc "End-to-end Kiosk skooti demo: setup the DB (B1 proof)."
task demo: ["demo:setup"]
