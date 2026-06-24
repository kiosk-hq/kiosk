# frozen_string_literal: true

# Kiosk demo orchestration. Three sub-tasks:
#
#   rake demo:setup        idempotent db:drop / create / migrate / seed
#   rake demo:walkthrough  boots the server, runs a curl-driven showcase,
#                          tears down
#   rake demo              setup + walkthrough end-to-end
#
# The walkthrough lives in bin/demo (POSIX shell) so it's debuggable
# without going through Rake.

namespace :demo do
  desc "Create + migrate + seed the demo database (idempotent)."
  task :setup do
    sh "psql -d postgres -tAc \"DO \\$\\$ BEGIN " \
       "IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_role') " \
       "THEN CREATE ROLE app_role NOLOGIN; END IF; END \\$\\$;\" >/dev/null"
    sh "psql -d postgres -tAc 'GRANT app_role TO CURRENT_USER' >/dev/null"
    sh "bundle exec rails db:drop db:create db:migrate db:seed"
  end

  desc "Boot the server and run the demo walkthrough."
  task :walkthrough do
    exec File.expand_path("../../bin/demo", __dir__)
  end
end

desc "End-to-end Kiosk demo: setup the DB then run the walkthrough."
task demo: ["demo:setup", "demo:walkthrough"]
