# frozen_string_literal: true

module Kiosk
  # Wire-protocol constants and HTTP header names for the version handshake.
  module Protocol
    # Semver of the wire protocol: one endpoint per verb under the mount
    # (`GET <endpoint>/<query-name>`, `POST <endpoint>/<action-name>`) plus the
    # reserved `GET <endpoint>/schema` and `POST <endpoint>/pay`.
    #
    # 0.5 is a BREAKING minor: the catalogue root is closed and `events` is
    # REQUIRED in it, so a client built for an earlier minor cannot read it.
    # Before 1.0 every gem, MIN_CLIENT and every pinned skill cut carry this
    # exact version (spec §14.1).
    API_VERSION = "0.5.4"

    # The oldest skill cut that can transact with this engine (spec §14.2,
    # §14.4: a 0.5.4 operator no longer serves the 0.5.0-0.5.3 cuts).
    # Advisory, in the Kiosk::Protocol::HEADER_MIN_CLIENT response header and
    # `kiosk.min_client`; older clients are expected to upgrade.
    MIN_CLIENT = "0.5.4"

    # HTTP response header names (sent on every /kiosk/* response).
    HEADER_SERVER_VERSION = "Kiosk-Server-Version"
    HEADER_API_VERSION    = "Kiosk-API-Version"
    HEADER_MIN_CLIENT     = "Kiosk-Min-Client"

    # HTTP REQUEST header names a caller may send.
    #
    # `Kiosk-Timezone` carries the CALLER's own clock as an IANA
    # `Area/Location` identifier (or the literal `UTC`), so an operator can
    # read a bare `YYYY-MM-DD` argument in the calendar the caller meant it in.
    # It is a fact about the caller, not about the verb, which is why it is a
    # header and not an argument in every time-bearing `input_schema`.
    HEADER_TIMEZONE = "Kiosk-Timezone"

    # Default URL prefix at which kiosk-server mounts its endpoints.
    # Provider may mount elsewhere; this is the suggested default and what
    # the well-known document advertises out-of-the-box.
    DEFAULT_MOUNT_PATH = "/kiosk"
  end
end
