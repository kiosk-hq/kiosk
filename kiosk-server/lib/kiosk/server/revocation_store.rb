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
    # what lets `/auth/revoke` hand back a replacement token minted immediately
    # after stamping. There the residual second is not a security boundary — the
    # caller holds the private key and can mint another token at will, so
    # revocation was never the defense.
    #
    # THAT ARGUMENT DOES NOT TRANSFER to a watermark stamped AGAINST the key's
    # current access, and BOTH such callers now pass the NEXT second so the
    # whole ambiguous second is covered:
    #
    #   * `unlink!` (K-835) — afterwards the key cannot log in at all, so a
    #     token slipping through the gap is the last one it will ever hold and
    #     it keeps full access for its remaining lifetime (measured 3600s).
    #     Nothing is returned, so nothing needs to survive.
    #   * the claim REBIND (K-836) — the pre-link tokens carry the previous
    #     principal and §6.3 says they MUST stop verifying. This caller DOES
    #     return a replacement, and §6.3 names `/auth/login` as a second way
    #     back in, so a `+1` watermark would have killed the very next token
    #     too. Neither is spared by a rule in the caller: the bundled IdP reads
    #     {#watermark_for} and dates every mint at the watermark when one is
    #     ahead of the clock, so a token issued AFTER a revocation is never
    #     born revoked.
    #
    # The comparison itself stays dumb: who is being revoked, and whether a
    # replacement token needs to survive, is the caller's knowledge, not this
    # class's.
    #
    # Mirrors {PowSpentStore}: Mutex-guarded, pruned opportunistically, and NOT
    # shared across web workers. Multi-process providers MUST override
    # `Kiosk.configure { |c| c.revocation_store = MyRedisRevocationStore.new }`;
    # the durable production home is the (already-provisioned) `agent_tokens`
    # table. The interface contract is:
    #
    #   revoke_all(agent_id, at:)        → void     (at is a Unix timestamp)
    #   revoked?(agent_id:, iat:)        → Boolean
    #   watermark_for(agent_id)          → Integer | nil
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

      # The agent's current watermark, or nil when nothing is revoked for it.
      #
      # Read by {AgentIdentityProviders::DefaultAgentIdp} so a freshly minted
      # token is never dated BEFORE a watermark that was just stamped — the one
      # place that keeps "revoke against this key" and "mint a token for this
      # key" from colliding inside a single second (K-836). Part of the store
      # interface: an override that omits it re-opens that aperture for its own
      # deployment rather than crashing.
      #
      # @return [Integer, nil] Unix timestamp
      def watermark_for(agent_id)
        return nil if agent_id.nil?

        prune!
        @mutex.synchronize { @store[agent_id] }
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
