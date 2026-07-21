# frozen_string_literal: true

require Rails.root.join("lib/demo_telemetry")

# GET /demo/activity.json — privacy-safe live-activity aggregates.
#
# Returns counts ONLY (no agent detail, no PII):
#   { assistants_active_10m, registered_total, actions_last_hour: {kind=>n},
#     generated_at, scope }
#
# scope=all (default, or ?scope=all) spans every app in the shared telemetry DB
# — the number the kiosk.tech landing tile fetches. scope=app (?scope=app)
# reports only THIS demo's activity for the demo's own page.
#
# Cache-friendly: a short Cache-Control so the landing tile / CDN can serve it
# without hammering the DB (aggregates move slowly; 10 s is plenty).
#
# Only mounted when KIOSK_TELEMETRY=1 (see config/initializers/kiosk.rb); when
# telemetry is off the route is not drawn and this returns 404 by absence.
class DemoActivityController < ActionController::Base
  def show
    scope_app = params[:scope].to_s == "app" ? DemoTelemetry.app_name : nil
    data = DemoTelemetry.aggregates(app: scope_app)

    response.set_header("Cache-Control", "public, max-age=10")
    response.set_header("Access-Control-Allow-Origin", "*") # landing tile fetch
    render json: data
  end
end
