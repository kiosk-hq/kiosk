# frozen_string_literal: true

module Kiosk
  module Pow
    module Equihash
      # In a Rails app, registers this verifier as the `equihash` proof-of-work
      # backend. The app needs kiosk-reputation, which holds the registry.
      class Railtie < Rails::Railtie
        initializer 'kiosk_pow_equihash.register_backend' do
          require 'kiosk/reputation/backends'
          Kiosk::Reputation::Backends.register(NAME, Equihash)
        end
      end
    end
  end
end
