# frozen_string_literal: true

module Kiosk
  # Wire-protocol version and header names.
  module Protocol
    # Before 1.0 every gem, MIN_CLIENT and every pinned skill cut carry this exact version (spec §14.1).
    API_VERSION = "0.5.12"

    # The oldest skill cut that can transact with this engine (spec §14.2). Advisory.
    MIN_CLIENT = "0.5.12"

    HEADER_SERVER_VERSION = "Kiosk-Server-Version"
    HEADER_API_VERSION    = "Kiosk-API-Version"
    HEADER_MIN_CLIENT     = "Kiosk-Min-Client"

    # Request header: the caller's IANA time zone, for reading a bare date argument.
    HEADER_TIMEZONE = "Kiosk-Timezone"

    DEFAULT_MOUNT_PATH = "/kiosk"
  end
end
