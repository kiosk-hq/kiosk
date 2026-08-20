# frozen_string_literal: true

require "json"
require "kiosk/server/actions"

module Kiosk
  module Server
    # THE AUDIT LOG — one row in `<schema>.action_log` per action INVOCATION
    # (T-088, Phil 2026-08-17: «у нас предполагается возможность аудита.
    # Запланируй, чтобы мы туда писали наши kiosk actions»).
    #
    # Canonical migration 003 has laid `<schema>.actions` and
    # `<schema>.action_log` down for every adopter since 0.1 and nothing ever
    # wrote them (K-791), so an operator carried an audit table whose emptiness
    # read as «no actions were invoked». The columns that migration already
    # declares are the CONTRACT this writer satisfies — `action_name` (FK),
    # `user_id`, `agent_id`, `role`, `actor`, `args`, `result_status`,
    # `error_class`, `error_message`, `invoked_at`. Nothing here redesigns
    # them.
    #
    # ── WHAT IS LOGGED, AND WHAT IS NOT ──────────────────────────────────
    #
    # ACTIONS ONLY — the `run` verb, i.e. every name in the {Actions}
    # registry. Three exclusions, each for its own reason:
    #
    #   * QUERIES are not logged. The table is `action_log`, its FK points at
    #     `actions(name)`, and a query changes nothing; logging every read
    #     would multiply the table by the least security-relevant events on
    #     the wire.
    #   * `pay` is not logged. It is a SELF_MANAGED_VERB with three
    #     transactions around an irreversible capture, and it already writes a
    #     far richer purpose-built trail — `intent_mandates`, `cart_mandates`,
    #     `payment_mandates` (each holding the signed `raw_jws`) and
    #     `settlements`. One redacted `action_log` row would add nothing an
    #     auditor needs, and it is not in the {Actions} registry, so the FK
    #     would need a synthetic anchor row for a verb that is not an Action.
    #   * REFUSALS THAT NEVER REACHED AN ACTION are not logged: a 401 with no
    #     identity, a 404 for a name nobody registered, a 405 for the other
    #     kind, a 400 from argument validation, a 402 from the toll. The
    #     table's own NOT NULLs draw that line for us — `user_id`, `role` and
    #     `actor` require a resolved identity, and `action_name` has to
    #     satisfy the FK, so a request refused before both of those exist has
    #     no row it could honestly occupy. This is an ACTION log, not a
    #     request log.
    #
    # A FAILED action DOES log, with `result_status = "error"`. The schema
    # settles it: `error_class` and `error_message` are meaningless columns
    # unless failures land, and an audit trail that records only successes is
    # the wrong shape for the security dimension — the refusals and the raises
    # are the interesting events.
    #
    # ── WHEN THE ROW IS WRITTEN: AFTER, NOT INSIDE ───────────────────────
    #
    # The row is written AFTER the action's {SessionContext} closes, in its
    # own transaction. The alternative — writing inside the action's
    # transaction — is atomic, and it is impossible here for two reasons:
    #
    #   1. IT CANNOT LOG A FAILURE. A failed action rolls its SessionContext
    #      back, and an in-transaction log row rolls back with it. So
    #      «failures log» and «same transaction» are mutually exclusive, and
    #      the audit trail wins.
    #   2. A LOG FAILURE MUST NOT ROLL BACK A GOOD ACTION. An operator's
    #      booking must not fail because the audit table is locked, full, or
    #      not migrated yet.
    #
    # The price is honest and stated: the log is LOSSY. A crash between the
    # action's COMMIT and this write loses the entry. A write that FAILS is
    # reported (`Rails.logger.error`, or `warn` outside Rails) and never
    # swallowed, so the loss is visible in the process log rather than
    # invisible in the table.
    #
    # ── OUTSIDE THE RLS BOUNDARY, DELIBERATELY ───────────────────────────
    #
    # The write does NOT open a {SessionContext}: no GUCs, no
    # `SET LOCAL ROLE`. The log crosses principals by construction — it is
    # the operator's oversight surface, not a per-principal resource — so:
    #
    #   * an RLS policy scoping it to `current_user_id()` would hide rows
    #     from the operator who needs to read them, and would make an audit
    #     table an agent's own session could enumerate;
    #   * writing as the connection's own role rather than as `app_role`
    #     means a caller's session privileges cannot suppress, alter or
    #     forge an audit row — which is the property an audit table needs;
    #   * no shipped migration enables RLS on `action_log`, so «outside» is
    #     also the status quo and costs no adopter a new migration.
    #
    # ── `<schema>.actions` IS POPULATED BY THIS WRITER ───────────────────
    #
    # The FK anchor is upserted in the same transaction as the row that needs
    # it, from the live {Actions} registry, rather than being seeded at boot.
    # {SchemaDocument} derives its boot-time artefact IN MEMORY, with no
    # database at all; a boot-time DB write is a genuinely different
    # mechanism, and one that breaks `db:create`, `db:migrate` and an
    # asset-precompile on a host with no database yet — and would be silently
    # undone by the `db:drop db:create` every demo's `demo:setup` runs while a
    # server is up. Upserting on the write path is self-healing: the anchor is
    # correct after any reset, at the cost of one `ON CONFLICT DO NOTHING`
    # INSERT per invocation, on a path that is already doing real writes.
    module ActionLog
      OK    = "ok"
      ERROR = "error"

      # `role` is NOT NULL in the shipped schema, and {Kiosk::Identity} allows
      # a role-less principal (roles are hook-or-absent). The empty string is
      # the sentinel: `Identity` normalises an empty role to nil, so no real
      # role can ever spell itself this way.
      NO_ROLE = ""

      # `error_message` is `text` and an exception message is unbounded — a
      # multi-kilobyte `ActiveRecord::StatementInvalid` carrying a whole
      # statement would otherwise land in every row of a failing deploy.
      MAX_ERROR_MESSAGE = 500

      # The three `audit_log_args` policies. See {redact}.
      ARG_POLICIES = %i[none keys full].freeze

      class << self
        # Records ONE invocation. Best-effort by contract: it returns false and
        # reports rather than raising, because this is called after the action
        # has already succeeded or failed and must not change that outcome.
        #
        # @param connection [#exec_query, #transaction] the same connection the
        #   action ran on, OUTSIDE any Kiosk SessionContext
        # @param identity [Kiosk::Identity] the resolved caller
        # @param name [String] the action's wire name — must be in {Actions}
        # @param args [Hash] the arguments as the handler received them; what
        #   actually lands is {redact}'s output
        # @param status [String] {OK} or {ERROR}
        # @param error [Exception, nil] the raised error, on the {ERROR} branch
        # @param invoked_at [Time] when the invocation STARTED, not when this
        #   row was written
        # @return [Boolean] true when a row landed
        def record(connection:, identity:, name:, args:, status:, error: nil,
                   invoked_at: Time.now, schema: nil)
          schema ||= Kiosk.configuration.schema
          connection.transaction do
            ensure_action!(connection, schema, name)
            insert_row(connection, schema, identity, name, args, status, error, invoked_at)
          end
          true
        rescue StandardError => e
          report(name, e)
          false
        end

        # True when this origin writes the audit log at all
        # (`Kiosk.configuration.audit_log`, default on) AND `name` is an
        # action the registry knows — the FK cannot be satisfied otherwise, so
        # a direct {Executor} call for an unregistered name is skipped rather
        # than reported as a failure.
        def loggable?(name)
          return false unless Kiosk.configuration.audit_log
          return false if name.nil? || name.to_s.empty?

          Actions.known.include?(name.to_s)
        end

        # WHAT LANDS IN `args`, AND WHY THE DEFAULT IS NOT VERBATIM (D6).
        #
        # Arguments carry whatever the operator's verb takes — a delivery
        # address, a passenger name, a party size, a payment reference. The
        # log is retained indefinitely, is not encrypted, and (see the class
        # doc) sits outside RLS, so logging them verbatim by default would
        # turn one decision about auditing into a decision about PII
        # retention that no operator was asked to make.
        #
        # `Kiosk.configuration.audit_log_args`:
        #
        #   :keys   DEFAULT — argument NAMES with their JSON TYPES in place of
        #           the values: `{"salon_id":"integer","slot":"string"}`. Says
        #           what shape was called with, discloses nothing.
        #   :none   `{}` — the names are withheld too.
        #   :full   verbatim. The operator's own call, made explicitly.
        #   #call   a callable `->(args) { … }` returning the Hash to store,
        #           for a per-verb or per-field policy.
        def redact(args, policy: Kiosk.configuration.audit_log_args)
          return normalize(policy.call(args)) if policy.respond_to?(:call)

          case policy.to_sym
          when :none then {}
          when :full then normalize(args)
          when :keys then type_map(args)
          else
            raise Errors::ConfigurationError,
                  "audit_log_args must be one of #{ARG_POLICIES.inspect} or a callable, " \
                  "got #{policy.inspect}"
          end
        end

        # THE READ SIDE, AND IT IS OPERATOR-SIDE ONLY (T-088 question 5).
        #
        # There is no wire verb for the audit log and none is planned: a verb
        # would put one principal's invocation history behind a token another
        # principal can hold, and the log deliberately crosses principals. An
        # operator reads it from a console, a rake task or their own admin
        # surface — this is that read, with the filters the shipped indexes
        # support (`user_id, invoked_at DESC` and `agent_id, invoked_at DESC`).
        #
        # @return [Array<Hash>] newest first
        def recent(connection:, limit: 50, user_id: nil, agent_id: nil,
                   action_name: nil, schema: nil)
          schema ||= Kiosk.configuration.schema
          binds   = []
          where   = []
          { "user_id" => user_id, "agent_id" => agent_id, "action_name" => action_name }
            .each do |column, value|
              next if value.nil?

              binds << value
              where << "#{column} = $#{binds.size}"
            end
          binds << Integer(limit)

          sql = <<~SQL
            SELECT id, action_name, user_id, agent_id, role, actor, args,
                   result_status, error_class, error_message, invoked_at
            FROM #{schema}.action_log
            #{where.empty? ? '' : "WHERE #{where.join(' AND ')}"}
            ORDER BY invoked_at DESC
            LIMIT $#{binds.size}
          SQL
          connection.exec_query(sql, "Kiosk action_log read", binds).to_a
        end

        private

        # The FK anchor. `description` is kept current from the registry, but
        # only WRITTEN when it changed — an unchanged description costs a
        # conflict and no row write.
        def ensure_action!(connection, schema, name)
          sql = <<~SQL
            INSERT INTO #{schema}.actions (name, description)
            VALUES ($1, $2)
            ON CONFLICT (name) DO UPDATE SET description = EXCLUDED.description
            WHERE #{schema}.actions.description IS DISTINCT FROM EXCLUDED.description
          SQL
          connection.exec_query(sql, "Kiosk action registry upsert",
                                [name.to_s, description_for(name)])
        end

        def insert_row(connection, schema, identity, name, args, status, error, invoked_at)
          # `$6::jsonb` is the one hand-written cast, for the same reason the
          # pay path casts `line_items`: the argument arrives as JSON TEXT and
          # the cast is what says «parse this», not «store a json string».
          sql = <<~SQL
            INSERT INTO #{schema}.action_log
              (action_name, user_id, agent_id, role, actor, args,
               result_status, error_class, error_message, invoked_at)
            VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7, $8, $9, $10)
          SQL
          connection.exec_query(sql, "Kiosk action_log insert", [
            name.to_s,
            identity.user_id,
            identity.agent_id,
            identity.role || NO_ROLE,
            identity.actor,
            JSON.generate(redact(args)),
            status.to_s,
            error && error.class.name,
            error && truncate(error.message),
            invoked_at,
          ])
        end

        def description_for(name)
          Actions.describe(name.to_s)[:description]
        rescue StandardError
          nil
        end

        def truncate(message)
          text = message.to_s
          return text if text.length <= MAX_ERROR_MESSAGE

          "#{text[0, MAX_ERROR_MESSAGE]}…"
        end

        def normalize(value) = value.is_a?(Hash) ? value : {}

        def type_map(args)
          return {} unless args.is_a?(Hash)

          args.to_h { |key, value| [key.to_s, json_type(value)] }
        end

        # JSON Schema's own type vocabulary, so the recorded shape reads in the
        # same words the verb's `input_schema` declares it in.
        def json_type(value)
          case value
          when nil            then "null"
          when true, false    then "boolean"
          when Integer        then "integer"
          when Float, Numeric then "number"
          when Array          then "array"
          when Hash           then "object"
          else "string"
          end
        end

        # A failed audit write is REPORTED, never raised and never silent —
        # the log is lossy by design (see the class doc) and a loss that
        # nothing announces is indistinguishable from an action nobody
        # invoked, which is the exact defect K-791 filed.
        def report(name, error)
          message = "[kiosk-server] audit log write failed for action #{name.inspect}: " \
                    "#{error.class}: #{error.message}"
          logger = defined?(::Rails) && ::Rails.respond_to?(:logger) ? ::Rails.logger : nil
          logger ? logger.error(message) : warn(message)
        end
      end
    end
  end
end
