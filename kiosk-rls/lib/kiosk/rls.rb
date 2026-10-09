# frozen_string_literal: true

# kiosk-rls — the Kiosk RLS DSL and SQL emitter.

require "kiosk"

require "kiosk/rls/version"
require "kiosk/rls/configuration_extension"
require "kiosk/rls/policy"
require "kiosk/rls/table"
require "kiosk/rls/emitter"
require "kiosk/rls/dsl"

# Outside Rails the host includes {Kiosk::RLS::DSL} itself.
require "kiosk/rls/railtie" if defined?(::Rails::Railtie)
