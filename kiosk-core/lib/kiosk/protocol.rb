# frozen_string_literal: true

module Kiosk
  # Protocol version and header names.
  module Protocol
    # Before 1.0 every gem and every pinned skill cut carry this exact version (spec §14.1).
    API_VERSION = '0.6.22'

    # The oldest skill cut that works with this release: same MAJOR.MINOR as
    # API_VERSION, no newer (spec §3.6). Advisory.
    MIN_CLIENT = '0.6.0'

    HEADER_SERVER_VERSION = 'Kiosk-Server-Version'
    HEADER_API_VERSION    = 'Kiosk-API-Version'
    HEADER_MIN_CLIENT     = 'Kiosk-Min-Client'

    # Request header: the caller's IANA time zone, for reading a bare date argument.
    HEADER_TIMEZONE = 'Kiosk-Timezone'

    DEFAULT_MOUNT_PATH = '/kiosk'
  end
end
