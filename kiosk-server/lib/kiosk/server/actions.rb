# frozen_string_literal: true

require "kiosk/server/errors"

module Kiosk
  module Server
    # Process-wide registry of Action handlers.
    #
    # Stub for v0.1 alpha. The full `Kiosk::Action` DSL (`description`,
    # `accepts`, `requires_payment`, `escalate_to :system`, etc.)
    # lands in a follow-up release. For now, register a
    # name + callable, fetch + invoke from {Executor}.
    #
    # @example
    #   Kiosk::Server::Actions.register("ping") { |args| { pong: args[:name] } }
    #   Kiosk::Server::Actions.fetch("ping").call({ name: "world" })
    #   # => { pong: "world" }
    #
    # Optional metadata for agent self-discovery (backward-compatible):
    #   Kiosk::Server::Actions.register("place_order", description: "Place an order",
    #                                                   params: { items: "array" }) { ... }
    #   Kiosk::Server::Actions.describe("place_order") # => { name:, description:, params: }
    #   Kiosk::Server::Actions.catalog                 # => sorted Array of descriptors
    module Actions
      # Internal entry holding a handler (callable) plus optional discovery metadata.
      # Defined at module scope so reset! can replace @registry without affecting the
      # constant. Not part of the public API — callers always go through fetch/describe/catalog.
      Entry = Data.define(:handler, :description, :params)

      class << self
        def register(name, callable = nil, description: nil, params: nil, &block)
          handler = callable || block
          raise ArgumentError, "register requires a callable or a block" if handler.nil?

          registry[name.to_s] = Entry.new(handler: handler, description: description, params: params)
        end

        def fetch(name)
          entry = registry.fetch(name.to_s) do
            raise Errors::NotFound.new(
              "Unknown action: #{name.inspect}",
              hint: "Known actions: #{registry.keys.inspect}",
            )
          end
          entry.handler
        end

        # Returns a descriptor Hash for the named action:
        #   { name: String, description: String|nil, params: any|nil }
        def describe(name)
          entry = registry.fetch(name.to_s) do
            raise Errors::NotFound.new(
              "Unknown action: #{name.inspect}",
              hint: "Known actions: #{registry.keys.inspect}",
            )
          end
          { name: name.to_s, description: entry.description, params: entry.params }
        end

        # Returns all registered actions as an Array of descriptor Hashes, sorted by name.
        def catalog
          registry.keys.sort.map { |name| describe(name) }
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
