# frozen_string_literal: true

require "active_support/core_ext/time/zones"
require "kiosk/protocol"
require "kiosk/server/errors"

module Kiosk
  module Server
    # `Kiosk-Timezone`: the zone of the human the assistant acts for, in which a
    # bare `YYYY-MM-DD` argument is read. It never decides how an answer is rendered.
    module CallerTimezone
      HEADER  = Kiosk::Protocol::HEADER_TIMEZONE
      ENV_KEY = "HTTP_KIOSK_TIMEZONE"

      # An IANA `Area/Location` name or `UTC` only: no offsets (no DST), no Rails
      # friendly names, no legacy ids like `EST`.
      SHAPE = %r{\A(?:UTC|[A-Za-z][A-Za-z0-9_+-]*(?:/[A-Za-z0-9_+-]+)+)\z}

      HINT = "send an IANA zone name — Area/Location (e.g. Europe/Dublin) or the literal UTC. " \
             "A UTC offset (+03:00) is not accepted: it cannot carry a DST transition. " \
             "Take the zone from the human you are acting for, never from the machine you run on."

      module_function

      # nil when the caller declared no zone; raises BadRequest on one it cannot read.
      def from_env(env)
        from_value(env && env[ENV_KEY])
      end

      def from_value(raw)
        value = raw.to_s.strip
        return nil if value.empty?

        refuse(raw) unless SHAPE.match?(value)
        zone = ::Time.find_zone(value)
        refuse(raw) if zone.nil?

        zone
      end

      # §9.1: refused by name, never silently reinterpreted.
      def refuse(raw)
        raise Errors::BadRequest.new(
          "invalid #{HEADER}: #{raw.to_s.strip.inspect}",
          hint: HINT,
        )
      end
    end
  end
end
