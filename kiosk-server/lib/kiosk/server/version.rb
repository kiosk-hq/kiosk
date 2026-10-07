# frozen_string_literal: true

module Kiosk
  module Server
    VERSION = "0.5.6"

    # The MAJOR of the Kiosk schema this gem installs. A genesis records it in
    # the database as `<schema>.schema_major()`; crossing a major re-emits that
    # function with the new number.
    SCHEMA_MAJOR = VERSION.split(".").first.to_i
  end
end
