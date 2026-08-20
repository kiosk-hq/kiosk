# frozen_string_literal: true

module Kiosk
  module Server
    # In-process per-agent "revoked-before" watermark denylist — the state
    # behind `POST /auth/revoke` ("log out my other sessions").
    #
    # {#revoke_all} records a watermark for an agent; every access token for
    # that agent whose `iat` is strictly BEFORE the watermark is thereafter
    # rejected by {JwtIssuer.verify}. Tokens minted at or after the watermark —
    # a fresh `/auth/login`, or the replacement token `/auth/revoke` itself
    # returns — stay valid. That is how revoke-all keeps the caller signed in
    # while dropping its siblings, without ever mutating already-issued tokens.
    #
    # A watermark, not a jti set, is the right primitive: "revoke everything for
    # this identity" must cover tokens that were issued before the call and are
    # unknown to it, and a monotonic per-agent timestamp does exactly that in
    # O(1) with no per-token bookkeeping.
    #
    # Strict less-than means a token minted in the SAME wall-clock second as the
    # watermark is not covered (JWT timestamps are second-resolution). That is
    # REQUIRED by `/auth/revoke` and by the claim rebind, which both hand back a
    # replacement token minted immediately after stamping: strict `<` is what
    # lets the replacement survive its own watermark. For those two the residual
    # second is not a security boundary — the caller holds the private key, and
    # can mint another token at will, so revocation was never the defense there.
    #
    # THAT ARGUMENT DOES NOT TRANSFER to a watermark stamped AGAINST the key
    # holder (K-835): after `unlink!` the key can no longer log in, so a token
    # that slips through the same-second gap is the last one it will ever hold
    # and it keeps working for its full remaining lifetime. A caller revoking
    # someone ELSE's key and minting no replacement must therefore pass the NEXT
    # second (`Time.now.to_i + 1`) so the whole second is covered — see
    # {AccountBinding.unlink!}. The store deliberately stays a dumb comparison:
    # who is being revoked, and whether a replacement token needs to survive, is
    # the caller's knowledge, not this class's.
    #
    # Mirrors {PowSpentStore}: Mutex-guarded, pruned opportunistically, and NOT
    # shared across web workers. Multi-process providers MUST override
    # `Kiosk.configure { |c| c.revocation_store = MyRedisRevocationStore.new }`;
    # the durable production home is the (already-provisioned) `agent_tokens`
    # table. The interface contract is:
    #
    #   revoke_all(agent_id, at:)        → void     (at is a Unix timestamp)
    #   revoked?(agent_id:, iat:)        → Boolean
    class RevocationStore
      # How long a watermark is retained. MUST exceed the longest possible token
      # lifetime + verifier leeway, so no still-valid pre-watermark token can
      # slip through after its watermark is pruned. Entries are one per revoked
      # agent, so a generous default costs almost nothing.
      DEFAULT_RETENTION = 86_400 # 24h

      def initialize(retention: DEFAULT_RETENTION)
        @store     = {}
        @retention = retention
        @mutex     = Mutex.new
      end

      # Revoke every token for +agent_id+ issued strictly before +at+ (Unix ts).
      def revoke_all(agent_id, at:)
        return if agent_id.nil?

        @mutex.synchronize do
          current = @store[agent_id]
          # Watermarks only move forward — a later revoke never un-revokes.
          @store[agent_id] = at.to_i if current.nil? || at.to_i > current
        end
      end

      # @return [Boolean] true iff a token with this +iat+ for +agent_id+ has
      #   been revoked.
      def revoked?(agent_id:, iat:)
        return false if agent_id.nil? || iat.nil?

        prune!
        @mutex.synchronize do
          watermark = @store[agent_id]
          !watermark.nil? && iat.to_i < watermark
        end
      end

      # Drop watermarks old enough that no token issued before them can still be
      # unexpired. Called automatically by {#revoked?}.
      def prune!
        cutoff = Time.now.to_i - @retention
        @mutex.synchronize { @store.reject! { |_, at| at <= cutoff } }
      end
    end
  end
end
