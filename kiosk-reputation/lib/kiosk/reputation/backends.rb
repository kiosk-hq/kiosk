# frozen_string_literal: true

module Kiosk
  module Reputation
    # Registry mapping algorithm names to PoW backend objects.
    #
    # A backend must respond to:
    #   .params(d:, **) -> Hash    — build challenge params for a difficulty tier
    #   .verify(salt:, params:, nonce:) -> Boolean — verify a submitted proof
    #
    # kiosk-pow registers itself here:
    #   Kiosk::Reputation::Backends.register("argon2id", Kiosk::Pow)
    #
    # kiosk-pow-cuckoo (Phase 2) will register:
    #   Kiosk::Reputation::Backends.register("cuckoo", Kiosk::PowCuckoo)
    module Backends
      @registry = {}

      class << self
        # Register a backend under an algorithm name.
        #
        # @param alg_name [String] name advertised in the challenge (e.g. "argon2id")
        # @param backend  [Object] must respond to .params and .verify
        def register(alg_name, backend)
          @registry[alg_name.to_s] = backend
        end

        # Fetch a backend by algorithm name.
        #
        # @param alg_name [String]
        # @return [Object]
        # @raise [KeyError] if the algorithm is not registered
        def fetch(alg_name)
          key = alg_name.to_s
          @registry.fetch(key) do
            raise KeyError,
              "Unknown PoW backend: #{key.inspect}. " \
              "Known algorithms: #{known.inspect}. " \
              "Register a backend with Kiosk::Reputation::Backends.register(#{key.inspect}, backend)."
          end
        end

        # @return [Array<String>] sorted list of registered algorithm names
        def known
          @registry.keys.sort
        end

        # Reset the registry (used in tests to avoid cross-example pollution).
        def reset!
          @registry = {}
        end
      end
    end
  end
end
