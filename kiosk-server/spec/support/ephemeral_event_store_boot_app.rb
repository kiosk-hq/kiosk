# frozen_string_literal: true

# The fresh-host boot behind spec/kiosk/server/ephemeral_event_store_boot_spec.rb
# (K-1804) — run as a SUBPROCESS, never loaded into the RSpec process, for
# default_role_boot_app.rb's reasons: booting Rails in-process leaks
# Rails.logger and ActionDispatch::Flash into unrelated controller specs, and a
# real adopter's app boots in its own process anyway.
#
# It builds a THROWAWAY Rails app in a temp dir, declares topics the way an
# operator's handler controller does, configures Kiosk the way their
# `config/initializers/kiosk.rb` does, boots it for real, and reports whether
# `Rails.application.initialize!` came back or raised.
#
# IT BOOTS IN PRODUCTION, and that is the point of the fixture rather than an
# incidental setting: the refusal is production-gated, because the in-process
# store is the CORRECT store for the suite and for a one-process `rails server`.
# `RAILS_ENV` is set below, before Rails is asked what environment it is in.
#
# WHY A REAL BOOT AND NOT ONLY THE UNIT EXAMPLES. The condition is asserted in
# ephemeral_event_store_spec.rb; what THIS file proves is the other half — that
# the engine's `after_initialize` block actually RAISES on it, that the topic
# roster it reads is the one the REGISTRY holds after `to_prepare` rebuilt it
# from `c.handlers` (not a value the fixture handed it), and that a correctly
# configured origin still comes up.
#
# Usage: ruby ephemeral_event_store_boot_app.rb <scenario>
# Scenarios (one per subprocess, because a Rails app boots once per process):
#
#   topic_without_store   a declared topic and no `event_store` — the
#                         configuration K-1804 makes unbootable.
#   topic_with_store      the shape the four topic-declaring demos, the e2e
#                         fixture and the generator template all ship.
#   no_topic              a handler with verbs and no topic at all, on the
#                         in-process default — which MUST boot exactly as before.

ENV["RAILS_ENV"] = "production"

require "bundler/setup"
require "fileutils"
require "json"
require "tmpdir"
require "kiosk/server"
require "action_controller/railtie"

SCENARIO = ARGV.fetch(0)
ROOT     = Dir.mktmpdir("kiosk-ephemeral-event-store-boot")
at_exit { FileUtils.remove_entry(ROOT) if File.directory?(ROOT) }

app = Class.new(Rails::Application) do
  config.root             = ROOT
  config.eager_load       = false
  config.enable_reloading = false
  config.secret_key_base  = "ephemeral-event-store-boot"
  config.logger           = Logger.new(IO::NULL)
  config.hosts.clear
end
Object.const_set(:EphemeralEventStoreBootApp, app)

# An operator's own handler controller, declared the way a demo declares one.
# The topic roster the engine reads is rebuilt from `c.handlers` by the
# `to_prepare` hook during the boot below, so this class is what puts `delivery`
# in front of the check.
class BootHandlerController < ActionController::API
  include Kiosk::Handler

  if SCENARIO != "no_topic"
    topic :delivery do
      description "Your order is on its way, or has arrived."
      payload_schema type: "object", additionalProperties: false,
                     properties: { order_id: { type: "string" } },
                     required: %w[order_id]
    end
  end

  kind :query
  description "Everything this origin sells."
  input_schema type: "object", additionalProperties: false, properties: {}
  output_schema type: "array", items: { type: "object" }
  def catalog
    render json: []
  end
end

# A stand-in for EventStores::ActiveRecord, which would want a database
# connection this fixture has no reason to provide. The engine's condition asks
# only whether the store IS the in-process default.
class DurableBootStore
  def append(_key, _event) = 1
  def since(_key, _id) = []
  def head = 0
  def truncated?(_key, _id) = false
end

Kiosk.configure do |c|
  c.issuer      = "http://localhost"
  c.user_model  = "User"
  c.signing_key = Kiosk::Server::SigningKey.generate
  c.handlers    = %w[BootHandlerController]

  case SCENARIO
  when "topic_without_store", "no_topic"
    nil # the default: `event_store` lazily becomes the in-process EventStore
  when "topic_with_store"
    c.event_store = DurableBootStore.new
  else
    raise ArgumentError, "unknown scenario #{SCENARIO.inspect}"
  end
end

report =
  begin
    Rails.application.initialize!
    {
      "booted" => true,
      "topics" => Kiosk::Server::Events.known,
      "store_class" => Kiosk.configuration.event_store.class.name,
    }
  rescue StandardError => e
    { "booted" => false, "error_class" => e.class.name, "message" => e.message }
  end

puts JSON.generate(report)
