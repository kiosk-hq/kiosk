# frozen_string_literal: true

module Kiosk
  module Reputation
    # Registry mapping algorithm names to PoW backend objects.
    #
    # A backend must respond to:
    #   .params(n:, k:) -> Hash    — build the challenge params for the algorithm
    #                                (equihash memory is fixed by (n,k); there is
    #                                no continuous difficulty dial — the policy
    #                                escalates by PROOF COUNT, not by params)
    #   .verify(salt:, params:, nonce:) -> Boolean — verify a submitted proof
    #
    # kiosk-pow-equihash registers itself here (the shipped default backend):
    #   Kiosk::Reputation::Backends.register("equihash", Kiosk::Pow::Equihash)
    #
    # Legacy/alternative backends register under their own name, e.g.
    # kiosk-pow (Argon2id, legacy) as "argon2id", or a future
    # kiosk-pow-cuckoo as "cuckoo".
    module Backends
      @registry = {}

      class << self
        # Register a backend under an algorithm name.
        #
        # @param alg_name [String] name advertised in the challenge (e.g. "equihash")
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
