# frozen_string_literal: true

# kiosk-server: the Rails engine, its wire, auth and discovery controllers, and
# the install generator. See https://kiosk.tech.

require 'kiosk'
require 'active_record'
require 'action_dispatch/routing'
require 'active_support/core_ext' # the core extensions a Rails host loads, which the engine's code uses
require 'zeitwerk'

Zeitwerk::Loader.for_gem_extension(Kiosk).setup

module Kiosk
  module Server
  end

  # The user id and role of the principal the wire resolved.
  def self.current_user_id = Server::SessionContext.identity.user_id
  def self.current_role    = Server::SessionContext.identity.role

  # The zone the caller declared in `Kiosk-Timezone`, else `default`. Never the clock of a service time.
  def self.reader_zone(default = nil) = Server::CurrentRequest.timezone || default

  # "<name> runs on <zone> time, 2 hours ahead of your <caller_zone>." when the two clocks
  # differ now, else nil. A place adds a second sentence: every time in the answer is the place's.
  def self.clock_gap_note(name, zone, caller_zone)
    return if caller_zone.nil?

    gap = zone.now.utc_offset - caller_zone.now.utc_offset
    return if gap.zero?

    hours = format('%g', gap.abs / 3600.0)
    "#{name} runs on #{zone.name} time, #{hours} #{hours == '1' ? 'hour' : 'hours'} " \
      "#{gap.positive? ? 'ahead of' : 'behind'} your #{caller_zone.name}."
  end
end

Kiosk::Configuration.include(Kiosk::Server::ConfigurationExtension)
ActionDispatch::Routing::Mapper.include(Kiosk::Server::Routing)
# Rails registers an engine when its class is defined.
Kiosk::Server::Engine
