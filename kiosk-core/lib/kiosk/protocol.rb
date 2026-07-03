# frozen_string_literal: true

module Kiosk
  # Wire-protocol constants and HTTP header names.
  # See design spec §3.2 «Distribution» for the version-handshake contract.
  module Protocol
    # Semver of the wire protocol exposed at /kiosk/query, /kiosk/run, /kiosk/pay, etc.
    # Changes more slowly than the server version itself.
    API_VERSION = "0.1.0"

    # Minimum kiosk CLI client version that can speak this API version.
    # Older clients must upgrade; the server returns Kiosk::Protocol::HEADER_MIN_CLIENT
    # on every response so the client can self-check.
    MIN_CLIENT = "0.1.0"

    # HTTP response header names (sent on every /kiosk/* response).
    HEADER_SERVER_VERSION = "Kiosk-Server-Version"
    HEADER_API_VERSION    = "Kiosk-API-Version"
    HEADER_MIN_CLIENT     = "Kiosk-Min-Client"

    # Well-known discovery path on the provider's origin.
    WELL_KNOWN_PATH = "/.well-known/kiosk.json"

    # Default URL prefix at which kiosk-server mounts its endpoints.
    # Provider may mount elsewhere; this is the suggested default and what
    # the well-known document advertises out-of-the-box.
    DEFAULT_MOUNT_PATH = "/kiosk"
  end
end
