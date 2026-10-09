# frozen_string_literal: true

module Kiosk
  module Server
    # Per-agent revocation watermark behind `POST /auth/revoke`: a token whose
    # `iat` is strictly before it stops verifying. In-process only; a
    # multi-process operator sets `c.revocation_store` to a shared store.
    class RevocationStore
      # Must exceed the longest token lifetime plus verifier leeway.
      DEFAULT_RETENTION = 86_400

      def initialize(retention: DEFAULT_RETENTION)
        @store     = {}
        @retention = retention
        @mutex     = Mutex.new
      end

      def revoke_all(agent_id, at:)
        return if agent_id.nil?

        @mutex.synchronize do
          current = @store[agent_id]
          @store[agent_id] = at.to_i if current.nil? || at.to_i > current
        end
      end

      # The IdP dates a new token no earlier than this, so it is never born revoked.
      def watermark_for(agent_id)
        return nil if agent_id.nil?

        prune!
        @mutex.synchronize { @store[agent_id] }
      end

      def revoked?(agent_id:, iat:)
        return false if agent_id.nil? || iat.nil?

        prune!
        @mutex.synchronize do
          watermark = @store[agent_id]
          !watermark.nil? && iat.to_i < watermark
        end
      end

      def prune!
        cutoff = Time.now.to_i - @retention
        @mutex.synchronize { @store.reject! { |_, at| at <= cutoff } }
      end
    end
  end
end
