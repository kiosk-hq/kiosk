# frozen_string_literal: true

module Kiosk
  module Reputation
    # Registry of PoW backends by algorithm name; a backend answers `.verify(salt:, params:, nonce:)`.
    # The host must register a backend before the first challenge verify — no
    # PoW gem self-registers on require. The shipped default:
    #   Kiosk::Reputation::Backends.register(Kiosk::Pow::Equihash::NAME, Kiosk::Pow::Equihash)
    module Backends
      @registry = {}

      class << self
        def register(alg_name, backend)
          @registry[alg_name.to_s] = backend
        end

        def fetch(alg_name)
          key = alg_name.to_s
          @registry.fetch(key) do
            raise KeyError,
              "Unknown PoW backend: #{key.inspect}. " \
              "Known algorithms: #{known.inspect}. " \
              "Register a backend with Kiosk::Reputation::Backends.register(#{key.inspect}, backend)."
          end
        end

        # Could a challenge minted at `params` ever verify? False only when the
        # registered backend's own optional `.valid_params?` says so.
        def valid_params?(alg_name, params)
          backend = @registry[alg_name.to_s]
          return true unless backend.respond_to?(:valid_params?)

          backend.valid_params?(params)
        end

        def known
          @registry.keys.sort
        end

        def reset!
          @registry = {}
        end
      end
    end
  end
end
