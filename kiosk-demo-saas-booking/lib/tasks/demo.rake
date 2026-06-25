# frozen_string_literal: true

# Kiosk demo orchestration. Three sub-tasks:
#
#   rake demo:setup        idempotent db:drop / create / schema:load / seed
#   rake demo:walkthrough  boots the server, runs a curl-driven showcase,
#                          tears down
#   rake demo              setup + walkthrough end-to-end
#
# The walkthrough lives in bin/demo (POSIX shell) so it's debuggable
# without going through Rake.

namespace :demo do
  desc "Create + load schema + seed the demo database (idempotent)."
  task :setup do
    sh "psql -d postgres -tAc \"DO \\$\\$ BEGIN " \
       "IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_role') " \
       "THEN CREATE ROLE app_role NOLOGIN; END IF; END \\$\\$;\" >/dev/null"
    sh "psql -d postgres -tAc 'GRANT app_role TO CURRENT_USER' >/dev/null"
    # Path C: schema_format = :sql, so db:schema:load loads structure.sql
    # directly (no RLS). Use db:schema:load instead of db:migrate so that
    # the canonical structure.sql (no ROW LEVEL SECURITY) is the source of truth.
    sh "bundle exec rails db:drop db:create db:schema:load db:seed"
  end

  desc "Boot the server and run the demo walkthrough."
  task :walkthrough do
    exec File.expand_path("../../bin/demo", __dir__)
  end
end

desc "End-to-end Kiosk demo: setup the DB then run the walkthrough."
task demo: ["demo:setup", "demo:walkthrough"]
