# frozen_string_literal: true

module Kiosk
  # Wire-protocol constants and HTTP header names for the version handshake.
  module Protocol
    # Semver of the wire protocol: one endpoint per verb under the mount
    # (`GET <endpoint>/<query-name>`, `POST <endpoint>/<action-name>`) plus the
    # reserved `GET <endpoint>/schema` and `POST <endpoint>/pay`. Changes more
    # slowly than the server version itself.
    #
    # 0.4 is a BREAKING minor: it deleted 0.3's multiplexed
    # `POST <endpoint>/{query,run}` and the `{ok, kind, rows|value}` response
    # envelope outright, with no tombstones (T-074 = A). `bin/check-version-parity`
    # binds every gemspec version, every inter-gem constraint and every pinned
    # skill_url to this constant's MAJOR.MINOR.
    API_VERSION = "0.4.0"

    # Minimum client version that can speak this API version. Advertised in
    # the Kiosk::Protocol::HEADER_MIN_CLIENT response header on every
    # /kiosk/* response; older clients are expected to upgrade.
    MIN_CLIENT = "0.4.0"

    # HTTP response header names (sent on every /kiosk/* response).
    HEADER_SERVER_VERSION = "Kiosk-Server-Version"
    HEADER_API_VERSION    = "Kiosk-API-Version"
    HEADER_MIN_CLIENT     = "Kiosk-Min-Client"

    # Default URL prefix at which kiosk-server mounts its endpoints.
    # Provider may mount elsewhere; this is the suggested default and what
    # the well-known document advertises out-of-the-box.
    DEFAULT_MOUNT_PATH = "/kiosk"
  end
end
