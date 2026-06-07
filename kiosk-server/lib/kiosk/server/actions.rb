# frozen_string_literal: true

require "kiosk/server/errors"

module Kiosk
  module Server
    # Process-wide registry of Action handlers.
    #
    # Stub for v0.1 alpha. The full `Kiosk::Action` DSL (`description`,
    # `accepts`, `requires_payment`, `escalate_to :system`, etc.) per
    # design spec §8 lands in a follow-up release. For now, register a
    # name + callable, fetch + invoke from {Executor}.
    #
    # @example
    #   Kiosk::Server::Actions.register("ping") { |args| { pong: args[:name] } }
    #   Kiosk::Server::Actions.fetch("ping").call({ name: "world" })
    #   # => { pong: "world" }
    module Actions
      class << self
        def register(name, callable = nil, &block)
          handler = callable || block
          raise ArgumentError, "register requires a callable or a block" if handler.nil?

          registry[name.to_s] = handler
        end

        def fetch(name)
          registry.fetch(name.to_s) do
            raise Errors::NotFound.new(
              "Unknown action: #{name.inspect}",
              hint: "Known actions: #{registry.keys.inspect}",
            )
          end
        end

        def known
          registry.keys
        end

        def reset!
          @registry = nil
        end

        private

        def registry
          @registry ||= {}
        end
      end
    end
  end
end
