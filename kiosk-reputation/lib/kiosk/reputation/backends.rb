# frozen_string_literal: true

module Kiosk
  module Reputation
    # Registry mapping algorithm names to PoW backend objects.
    #
    # A registered backend need only respond to:
    #   .verify(salt:, params:, nonce:) -> Boolean — verify a submitted proof
    #
    # It MAY also respond to:
    #   .valid_params?(params) -> Boolean — could a proof at these parameters
    #   ever verify? Optional and duck-typed (K-843): a backend that does not
    #   implement it is simply unconstrained, and {valid_params?} says so by
    #   answering true.
    #
    # {Challenge.verify} resolves a backend via {fetch} and calls only its
    # .verify. (Backends also expose a .params helper for building challenge
    # params, but its signature is algorithm-specific — equihash takes (n:, k:),
    # argon2id takes (d:, m:, t:, p:), cuckatoo takes (edgebits:, proofsize:,
    # target:) — and it is called directly on the concrete backend by the host,
    # never through this registry.)
    #
    # The host must register a backend before the first challenge verify — no
    # PoW gem self-registers on require. The shipped default:
    #   require "kiosk/pow/equihash"
    #   Kiosk::Reputation::Backends.register(Kiosk::Pow::Equihash::NAME, Kiosk::Pow::Equihash)
    #
    # Alternative backends register under their own name, e.g. kiosk-pow
    # (Argon2id, legacy) as "argon2id", or kiosk-pow-cuckoo (opt-in) as
    # "cuckatoo" (Kiosk::Pow::Cuckoo::NAME).
    module Backends
      @registry = {}

      class << self
        # Register a backend under an algorithm name.
        #
        # @param alg_name [String] name advertised in the challenge (e.g. "equihash")
        # @param backend  [Object] must respond to .verify(salt:, params:, nonce:)
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

        # Would a challenge minted at `params` be answerable by the backend
        # registered for `alg_name`? (K-843)
        #
        # The seam a MINTING gate asks before it issues. {Challenge.issue} is
        # deliberately algorithm-agnostic — it takes any `alg` + `params` Hash
        # and only HMACs them — so a degenerate difficulty is minted happily and
        # only discovered when an honest solve fails verification, at which
        # point the agent is told its correct proof was invalid and the operator
        # is told nothing. This lets the gate refuse at the right end.
        #
        # NEVER INVENTS A REFUSAL. Answers false only when a registered backend
        # says so itself. An unregistered algorithm, or a backend that does not
        # implement `.valid_params?`, cannot answer the question — and a seam
        # that cannot answer must not manufacture a rejection, so both are true.
        # (An unregistered algorithm is a different misconfiguration; {fetch}
        # still reports it, with the list of names that ARE registered.)
        #
        # @param alg_name [String] name advertised in the challenge
        # @param params   [Hash]   the algorithm-specific params about to be minted
        # @return [Boolean]
        def valid_params?(alg_name, params)
          backend = @registry[alg_name.to_s]
          return true unless backend.respond_to?(:valid_params?)

          backend.valid_params?(params)
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
