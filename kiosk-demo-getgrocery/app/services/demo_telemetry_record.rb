# frozen_string_literal: true

# Throwaway AR model that binds to the shared telemetry DB URL when the hosted
# deploy sets KIOSK_TELEMETRY_DB_URL. Unused in the local/CI single-DB path.
class DemoTelemetryRecord < ActiveRecord::Base
  self.abstract_class = true
end
