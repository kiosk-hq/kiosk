# frozen_string_literal: true

require 'kiosk/pow'
require 'kiosk/pow/cuckoo/version'
require 'kiosk/pow/cuckoo/sip_hash'

module Kiosk
  module Pow
    # Cuckatoo Cycle proof-of-work verifier, clean-room from Tromp's spec.
    # The proof `nonce` is { header_nonce: <u32>, cycle: [42 ascending edge indices] };
    # the solver is `solve_cuckoo.py`, packaged beside this file.
    module Cuckoo
      NAME = 'cuckatoo'

      def self.siphash(key0, key1, key2, key3, nonce)
        SipHash.digest([key0, key1, key2, key3], nonce)
      end

      def self.verify_cycle(keys:, edgebits:, cycle:, proofsize: 42) # rubocop:disable Naming/PredicateMethod -- public verifier step, named like the PoW backend interface method verify.
        return false unless cycle.length == proofsize

        uvs = endpoints(keys, edgebits, cycle)
        !uvs.nil? && closed_walk_length(uvs) == proofsize
      end

      # `target` is a 256-bit Integer the sorted cycle's BLAKE2b-256 must stay below; nil accepts any cycle.
      def self.params(edgebits:, proofsize: 42, target: nil)
        { edgebits:, proofsize:, target: }
      end

      def self.verify(salt:, params:, nonce:)
        proof = coerce_proof(nonce)
        edgebits, proofsize, target = coerce_params(params)
        return false if proof.nil? || edgebits.nil?

        header_nonce, cycle = proof
        keys = Blake2b.digest256(salt.b + [header_nonce].pack('V')).unpack('Q<4')
        verify_cycle(keys:, edgebits:, cycle:, proofsize:) && below_target?(cycle, target)
      end

      # The two node endpoints of each edge, in cycle order. Nil when an edge is
      # not an Integer, is out of range, or breaks the ascending order.
      def self.endpoints(keys, edgebits, cycle)
        n_nodes = 1 << edgebits
        return nil unless ascending_edges?(cycle, n_nodes)

        mask = n_nodes - 1
        cycle.flat_map { |edge| [siphash(*keys, 2 * edge) & mask, siphash(*keys, (2 * edge) + 1) & mask] }
      end

      def self.ascending_edges?(cycle, limit)
        cycle.each_with_index.all? do |edge, index|
          edge.is_a?(Integer) && edge < limit && (index.zero? || edge > cycle[index - 1])
        end
      end

      # Walks the cycle from endpoint 0: go to the one other same-parity
      # endpoint on the same node (>> 1), cross that edge (j ^ 1), and count the
      # steps back to 0. Nil when an endpoint has no partner or more than one.
      def self.closed_walk_length(uvs)
        i = 0
        steps = 0
        loop do
          j = partner(uvs, i)
          return nil if j.nil? || uvs[j] == uvs[i]

          i = j ^ 1
          steps += 1
          return steps if i.zero?
        end
      end

      def self.partner(uvs, from)
        node = uvs[from] >> 1
        matches = (1...(uvs.size / 2)).map { |step| (from + (2 * step)) % uvs.size }
                                      .select { |k| (uvs[k] >> 1) == node }
        matches.one? ? matches.first : nil
      end

      # [header_nonce, cycle] from a proof Hash; nil when it is unreadable.
      def self.coerce_proof(nonce)
        return nil unless nonce.is_a?(Hash)

        header_nonce = Pow.param(nonce, :header_nonce)
        cycle = Pow.param(nonce, :cycle)
        return nil if header_nonce.nil? || !cycle.is_a?(Array)

        [Integer(header_nonce), cycle]
      rescue ArgumentError, TypeError
        nil
      end

      # All-nil when unreadable, so {.verify} answers false instead of raising.
      def self.coerce_params(params)
        return [nil, nil, nil] unless params.is_a?(Hash)

        target = Pow.param(params, :target)
        [Integer(Pow.param(params, :edgebits)), Integer(Pow.param(params, :proofsize) || 42), target && Integer(target)]
      rescue ArgumentError, TypeError
        [nil, nil, nil]
      end

      # The sorted cycle's BLAKE2b-256, read as a big-endian integer, must be
      # below `target`. A nil target accepts any cycle.
      def self.below_target?(cycle, target)
        target.nil? || Blake2b.digest256(cycle.sort.pack('Q<*')).unpack1('H*').to_i(16) < target
      end

      private_class_method :endpoints, :ascending_edges?, :closed_walk_length, :partner,
                           :coerce_proof, :coerce_params, :below_target?
    end
  end
end
