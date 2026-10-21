# frozen_string_literal: true

module Kiosk
  # Shape check for request-supplied uuids, so a malformed id is a typed 4xx rather
  # than a 500 from Postgres or a false ownership refusal from Active Record's
  # NULL cast. Format only: it says nothing about whether the row exists.
  module UuidCheck
    # Canonical 8-4-4-4-12 only, so a refusal can name exactly what to send.
    PATTERN = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    def self.valid?(value)
      PATTERN.match?(value.to_s)
    end
  end
end
