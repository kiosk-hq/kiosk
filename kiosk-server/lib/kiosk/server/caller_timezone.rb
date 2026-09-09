# frozen_string_literal: true

require "active_support/core_ext/time/zones"
require "kiosk/protocol"
require "kiosk/server/errors"

module Kiosk
  module Server
    # ── THE CALLER'S OWN CLOCK, READ ONCE PER REQUEST ────────────────────────
    #
    # `Kiosk-Timezone: Europe/Istanbul` — the zone of the HUMAN the assistant is
    # acting for. It exists so that a bare `YYYY-MM-DD` ARGUMENT can be read in
    # the calendar the caller meant it in: «tonight» at 23:05 on the 6th is a
    # different day from «tonight» five minutes later in a shop three hours
    # ahead, and without this header an operator has no way to tell the two
    # apart.
    #
    # WHAT IT IS NOT. It never decides how an ANSWER is rendered. An answer is
    # rendered at the place the service happens — this restaurant, this
    # property, this delivery address — and that zone is a property of the
    # RESOURCE, which is operator data this gem knows nothing about. The engine
    # reads the caller's clock and hands it down; where the answer's clock comes
    # from is the operator's business and stays there.
    #
    # A HEADER RATHER THAN AN ARGUMENT, for two reasons that are both about the
    # descriptor: it is a fact about the CALLER and not about the verb, and a
    # descriptor is a CLOSED object, so as an argument it would be a published
    # slot every operator could spell differently. Declared once, in the spec,
    # for every origin.
    #
    # A HEADER RATHER THAN A PROPERTY OF THE REGISTERED IDENTITY, because an
    # identity travels: a zone frozen at registration is wrong the first time
    # anyone boards a plane, and nothing on the wire would say so. A shared list
    # read by two people is two clocks over one row.
    module CallerTimezone
      HEADER  = Kiosk::Protocol::HEADER_TIMEZONE
      ENV_KEY = "HTTP_KIOSK_TIMEZONE"

      # AN IANA `Area/Location` NAME, OR THE LITERAL `UTC`. NOTHING ELSE.
      #
      # A UTC OFFSET IS REFUSED, and that is the point of the shape rather than
      # an accident of it: `+03:00` cannot express a DST transition, so an
      # operator holding one cannot say which side of a boundary a FUTURE date
      # falls on, and «the caller's tomorrow» becomes unanswerable across one.
      #
      # Rails' own friendly names (`Central Time (US & Canada)`) and the
      # single-word backward-compatibility ids (`EST`) resolve in
      # ActiveSupport and are refused here anyway: one declared type admits one
      # spelling, and an origin that accepted three would make an assistant
      # guess which of them this origin is.
      SHAPE = %r{\A(?:UTC|[A-Za-z][A-Za-z0-9_+-]*(?:/[A-Za-z0-9_+-]+)+)\z}

      HINT = "send an IANA zone name — Area/Location (e.g. Europe/Dublin) or the literal UTC. " \
             "A UTC offset (+03:00) is not accepted: it cannot carry a DST transition. " \
             "Take the zone from the human you are acting for, never from the machine you run on."

      module_function

      # @param env [Hash, nil] the OUTER Rack env of the wire request
      # @return [ActiveSupport::TimeZone, nil] the caller's declared zone, or
      #   nil when it declared none
      # @raise [Errors::BadRequest] when it declared one this wire cannot read
      def from_env(env)
        from_value(env && env[ENV_KEY])
      end

      # @param raw [String, nil] the header value as sent
      def from_value(raw)
        value = raw.to_s.strip
        return nil if value.empty?

        refuse(raw) unless SHAPE.match?(value)
        zone = ::Time.find_zone(value)
        refuse(raw) if zone.nil?

        zone
      end

      # SPEC §9.1's FIRST BRANCH: a value outside its declared domain is refused
      # BY NAME, never silently reinterpreted. Falling back on a zone we could
      # not read would answer in a clock the caller did not ask for and did not
      # get told about — a wrong answer shaped exactly like a right one, which
      # is the whole class this header exists to remove.
      def refuse(raw)
        raise Errors::BadRequest.new(
          "invalid #{HEADER}: #{raw.to_s.strip.inspect}",
          hint: HINT,
        )
      end
    end
  end
end
