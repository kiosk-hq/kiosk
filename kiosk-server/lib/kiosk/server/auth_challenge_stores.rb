# frozen_string_literal: true

module Kiosk
  module Server
    # Shared-store adapters for the auth-challenge nonce table (K-751).
    #
    # The DEFAULT challenge store is {Kiosk::Server::AuthChallengeStore} — a
    # Hash + Mutex living in ONE process (`configuration_extension.rb`,
    # `auth_challenge_store`). §15.2 puts the server-held auth nonces of §5.1
    # under the same sharing requirement as the PoW spent-id set, and this
    # module is the referent implementation that sentence needs:
    #
    #   Kiosk.configure do |c|
    #     c.auth_challenge_store = Kiosk::Server::AuthChallengeStores::ActiveRecord.new
    #   end
    #
    # == How this differs from the PoW case, and why it is not a security row
    #
    # The two stores fail in OPPOSITE directions, and confusing them is how this
    # gets mis-filed. An unshared spent-id set ACCEPTS a proof it should reject
    # (fail-open — a replay). An unshared challenge store cannot FIND a nonce
    # issued elsewhere, so `GET /auth/challenge` on worker A followed by
    # `POST /auth/{register,login}` on worker B is simply REJECTED (fail-closed).
    # What is missing above `WEB_CONCURRENCY = 1` is therefore availability and
    # portability, not a control: the handshake succeeds only when both requests
    # happen to land on the same worker — roughly 1/N of the time — and the
    # failure reaches the AI assistant as an unexplained rejection of a
    # correctly-signed request, indistinguishable from a bad key.
    #
    # Naming note: the in-process store keeps its existing top-level constant
    # ({AuthChallengeStore}) rather than moving to
    # `AuthChallengeStores::InMemory` — renaming it would break every operator
    # initializer that references it. Same call as {PowSpentStores}.
    module AuthChallengeStores
      # Challenge store backed by the `<schema>.auth_challenges` table
      # ({SchemaDefinitions.auth_challenge_sql}), shared by every process
      # pointed at the same database. SQL with BIND PARAMETERS through the
      # host's `::ActiveRecord::Base.lease_connection` — the same access idiom
      # as {PowSpentStores::ActiveRecord} and
      # {DeviceAuthorizationStores::ActiveRecord}, so no model class is defined
      # and satellite neutrality holds.
      #
      # == Why the table is not in the install generator
      #
      # The six canonical migrations are what EVERY operator needs. This table
      # is needed only above `WEB_CONCURRENCY=1`, so it ships as SQL plus this
      # adapter and the operator adds the one-line migration when they scale
      # out. See the kiosk-server README, "Multi-process deployments".
      #
      # == The one behaviour that is NOT identical to the in-process store
      #
      # {AuthChallengeStore#take} compares the nonce with
      # `OpenSSL.fixed_length_secure_compare`; here the comparison is a SQL
      # equality inside the DELETE's WHERE clause, which is not constant-time.
      # That is the price of `take` being ONE statement — the row, not Ruby,
      # has to decide the single-use winner, and a SELECT-then-compare-then-
      # DELETE reintroduces the race the single-use property exists to close.
      # The exposure is a timing signal on a 256-bit random nonce, measured
      # across a database round trip, by an attacker who must already know the
      # public key the challenge was issued to; the ACCEPTED set is identical
      # either way, including that a wrong nonce does NOT consume the
      # outstanding challenge.
      class ActiveRecord
        # Seconds between opportunistic TTL sweeps. The sweep bounds table
        # growth, NOT correctness (an expired row can never be taken — every
        # statement below carries its own `expires_at > now()`), so it is
        # throttled hard rather than run on every call. Same knob and same
        # reason as {PowSpentStores::ActiveRecord}.
        DEFAULT_PRUNE_INTERVAL = 60

        # @param prune_interval [Integer] seconds; 0 sweeps on every put
        def initialize(prune_interval: DEFAULT_PRUNE_INTERVAL)
          @prune_interval = prune_interval
          @last_prune_at  = 0
          @mutex          = Mutex.new
        end

        # Record +nonce+ as the outstanding challenge for +public_key_pem+ until
        # Unix timestamp +exp+. Overwrites any prior challenge for the same key
        # — only the most recently issued challenge is valid, which the PRIMARY
        # KEY plus `ON CONFLICT DO UPDATE` states as one statement rather than a
        # delete-then-insert.
        #
        # The PEM is CALLER-SUPPLIED (it is the request's query parameter), so
        # it is `$1`; `exp` is derived server-side but is still a value, so it
        # is `$2` inside `to_timestamp`.
        #
        # No `max_entries` cap, unlike the in-process store: that cap exists
        # because a distinct-key flood on the unauthenticated
        # `GET /auth/challenge` can hold rate x TTL live entries in a Ruby
        # process's heap (K-548). A table is bounded by disk rather than by
        # RSS, and evicting the oldest LIVE row would need a second statement
        # and an ordering index for a bound the TTL sweep already approximates.
        # An operator who needs a hard cap enforces it at the edge, where the
        # request rate is.
        def put(public_key_pem, nonce, exp)
          return if public_key_pem.nil?

          prune_if_due!
          sql = <<~SQL
            INSERT INTO #{table} AS c (public_key, nonce, expires_at)
            VALUES ($1, $2, to_timestamp($3))
            ON CONFLICT (public_key) DO UPDATE
              SET nonce = EXCLUDED.nonce, expires_at = EXCLUDED.expires_at
          SQL
          connection.exec_query(sql, "Kiosk auth_challenge put", [public_key_pem, nonce, exp.to_i])
          nil
        end

        # Consume the challenge for +public_key_pem+ iff one exists, matches
        # +nonce+, and has not expired. Single-use.
        #
        # ONE atomic `DELETE … RETURNING`: the row decides the winner, so two
        # processes presenting the same challenge produce exactly one `true`
        # even though neither can see the other's Ruby state. A read-then-delete
        # would let both through, which is the whole reason this adapter exists.
        #
        # @return [Boolean]
        def take(public_key_pem, nonce)
          return false if public_key_pem.nil? || nonce.nil?

          sql = <<~SQL
            DELETE FROM #{table}
            WHERE public_key = $1 AND nonce = $2 AND expires_at > now()
            RETURNING public_key
          SQL
          rows = connection.exec_query(
            sql, "Kiosk auth_challenge take", [public_key_pem, nonce]
          ).to_a
          !rows.empty?
        end

        # Delete every challenge whose expiry has passed. Called
        # opportunistically by {#put} at most once per +prune_interval+ per
        # process; also safe to schedule as a periodic job instead.
        def prune!
          # No values at all — `now()` is the server's.
          connection.exec_query(%(DELETE FROM #{table} WHERE expires_at <= now()),
                                "Kiosk auth_challenge prune")
          nil
        end

        private

        def prune_if_due!
          now = Time.now.to_i
          due = @mutex.synchronize do
            if now - @last_prune_at >= @prune_interval
              @last_prune_at = now
              true
            else
              false
            end
          end
          prune! if due
        end

        # `lease_connection`, not `connection` (K-782): the latter is
        # soft-deprecated in Rails 8.1 and RAISES under
        # `permanent_connection_checkout = :disallowed`, and this store sits in
        # front of `/auth/challenge` and both `/auth/{register,login}` calls, so
        # that would be a 500 on the handshake itself.
        def connection = ::ActiveRecord::Base.lease_connection
        def table = %("#{Kiosk.configuration.schema}".auth_challenges)
      end
    end
  end
end
