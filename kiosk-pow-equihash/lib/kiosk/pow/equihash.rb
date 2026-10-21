# frozen_string_literal: true

require 'kiosk/pow'
require_relative 'equihash/version'

module Kiosk
  module Pow
    # Equihash proof-of-work verifier (Biryukov & Khovratovich, 2016); default n=168, k=7.
    # The solver finds 2^k nonces whose BLAKE2b-256(seed ‖ nonce) outputs
    # XOR to zero in the first n bits and form a valid Wagner collision tree.
    module Equihash
      NAME = 'equihash'

      DEFAULT_N = 168
      DEFAULT_K = 7

      # Upper bounds: `pack` truncates a larger Integer instead of raising, which would make one proof many.
      MAX_INDEX = 1 << 64
      MAX_HEADER_NONCE = 1 << 32

      # A leaf is `n / 8` bytes of a 256-bit digest: below 8 or above 256 bits every check passes.
      MIN_N = 8
      MAX_N = 256

      # n must be a multiple of 8 and n / (k + 1) at most 24; bench/ holds the measured grid.
      def self.params(n: 168, k: 7) # rubocop:disable Naming/MethodParameterName -- n and k are the Equihash parameters and the wire params keys.
        { n:, k: }
      end

      # Mint-time check: false iff no proof at these parameters could verify.
      def self.valid_params?(params)
        n, k = coerce_params(params)
        return false if n.nil?

        return false if k.negative?
        return false unless n.between?(MIN_N, MAX_N)

        (n / (k + 1)).positive?
      end

      def self.coerce_params(params)
        return [nil, nil] unless params.is_a?(Hash)

        [Integer(Pow.param(params, :n) || DEFAULT_N), Integer(Pow.param(params, :k) || DEFAULT_K)]
      rescue ArgumentError, TypeError
        [nil, nil]
      end
      private_class_method :coerce_params

      # Checks run cheapest-first: this is reachable unauthenticated on `POST /kiosk/oauth/register`.
      def self.verify(salt:, params:, nonce:) # rubocop:disable Naming/PredicateMethod -- the PoW backend interface name.
        indices = proof_indices(nonce)
        return false unless indices && valid_params?(params)

        n, k = coerce_params(params)
        return false unless well_formed_indices?(indices, k) && canonical_order?(indices, k)

        header_nonce = coerce_header_nonce(nonce)
        return false unless header_nonce

        tree_cancels?(salt.b + [header_nonce].pack('V'), indices, n, k)
      end

      def self.proof_indices(nonce)
        return unless nonce.is_a?(Hash)

        indices = Pow.param(nonce, :indices)
        indices if indices.is_a?(Array)
      end
      private_class_method :proof_indices

      # Exactly 2^k distinct indices, each a u64.
      def self.well_formed_indices?(indices, levels)
        expected_len = 1 << levels
        indices.length == expected_len &&
          indices.all? { |idx| idx.is_a?(Integer) && idx >= 0 && idx < MAX_INDEX } &&
          indices.uniq.length == expected_len
      end
      private_class_method :well_formed_indices?

      # Zcash canonical order: at every tree node the left half's first index precedes the right half's.
      def self.canonical_order?(indices, levels)
        (0...levels).all? do |level|
          half = 1 << level
          (0...indices.length).step(half * 2).all? { |base| indices[base] < indices[base + half] }
        end
      end
      private_class_method :canonical_order?

      def self.coerce_header_nonce(nonce)
        value = Integer(Pow.param(nonce, :header_nonce) || 0)
        value if value >= 0 && value < MAX_HEADER_NONCE
      rescue ArgumentError, TypeError
        nil
      end
      private_class_method :coerce_header_nonce

      # Fold the tree left to right, checking each node as soon as it exists, so a wrong proof stops early.
      # The levels cover k * n / (k + 1) bits; the root must cancel all n.
      def self.tree_cancels?(seed, indices, bits, levels)
        step  = bits / (levels + 1)
        stack = [] # completed subtrees, left to right: [height, xor]
        indices.each do |index|
          return false unless fold_leaf?(stack, leaf_hash(seed, index, bits / 8), bits, step)
        end
        stack.last[1].zero?
      end
      private_class_method :tree_cancels?

      # Pushes a leaf and merges each completed sibling subtree into it.
      # False when a merged node does not cancel its first `height * step` bits.
      def self.fold_leaf?(stack, node, bits, step)
        height = 0
        while stack.last&.first == height
          node ^= stack.pop[1]
          height += 1
          return false unless (node >> (bits - (height * step))).zero?
        end
        stack << [height, node]
        true
      end
      private_class_method :fold_leaf?

      # BLAKE2b-256(seed ‖ LE64(index)), first `n_bytes` read as a big-endian integer.
      def self.leaf_hash(seed, index, n_bytes)
        digest = Blake2b.digest256(seed + [index].pack('Q<'))
        digest.byteslice(0, n_bytes).unpack('C*').reduce(0) { |acc, b| (acc << 8) | b }
      end
      private_class_method :leaf_hash
    end
  end
end

require_relative 'equihash/railtie' if defined?(Rails::Railtie)
