# frozen_string_literal: true

require "kiosk/server/action_event"

module Kiosk
  module Server
    # THE AUDIT SEAM — Kiosk offers the capability, the operator owns the data.
    #
    # `Kiosk.configuration.audit_sink` is a callable the operator sets. When it
    # is set, {Executor} builds one {ActionEvent} per `run` invocation —
    # success and failure alike — and this module hands it over. When it is
    # NOT set (the default) nothing is emitted, nothing is built, and Kiosk
    # writes nothing anywhere.
    #
    #   Kiosk.configure do |c|
    #     c.audit_sink = ->(event) { AuditLog.create!(**event.to_h) }
    #   end
    #
    # Any `#call`-able object satisfies it — a lambda, or an instance of a
    # class of yours if the sink has state (a Kafka producer, a syslog socket).
    # This is the same shape as `c.on_bad_proof` and `c.reputation_factors`,
    # and the writer rejects a non-callable at CONFIGURE time so a typo is a
    # boot failure rather than a silently missing audit trail.
    #
    # ── WHY THERE IS NO TABLE BEHIND THIS ────────────────────────────────
    #
    # There was one. `kiosk.actions` / `kiosk.action_log` were canonical
    # migration 003 and `Kiosk::Server::ActionLog` (both since deleted) wrote a
    # row per invocation (T-088).
    # Phil reversed that on 2026-08-20 — «Хранить в БД в рамках kiosk
    # reference impl/demo не будем. Дадим интерфейс для возможности их
    # куда-то выливать по желанию оператора, и на его ответственность по
    # PII» — and the two tables left the canonical set with the writer.
    # Kiosk storing an audit trail means Kiosk owning retention, encryption,
    # purge and somebody else's PII; offering the seam means the operator
    # owns all four, deliberately, in a place they chose. See {ActionEvent}
    # for what arrives and for the redaction helpers.
    #
    # ── WHAT IS EMITTED, AND WHAT IS NOT ─────────────────────────────────
    #
    # ACTIONS ONLY — the `run` verb, and only names the {Actions} registry
    # knows. Three exclusions survive the reversal unchanged, because each
    # had its own reason:
    #
    #   * QUERIES are not emitted. A query changes nothing, and emitting
    #     every read would drown the trail in the least security-relevant
    #     events on the wire.
    #   * `pay` is not emitted. It is a SELF_MANAGED_VERB around an
    #     irreversible capture and it already writes a far richer
    #     purpose-built trail — `intent_mandates`, `cart_mandates`,
    #     `payment_mandates` (each holding the signed `raw_jws`) and
    #     `settlements`. One event would add nothing an auditor needs.
    #   * REFUSALS THAT NEVER REACHED AN ACTION are not emitted: a 401 with
    #     no identity, a 404 for a name nobody registered, a 405 for the
    #     other kind, a 400 from argument validation, a 402 from the toll.
    #     Nothing was invoked, so there is no invocation to report. This is
    #     an ACTION trail, not a request log — put a Rack middleware in front
    #     of the engine if a request log is what you want.
    #
    # A FAILED action DOES emit, with `status = "error"` and the error's class
    # and message. An audit trail that records only successes is the wrong
    # shape for the one dimension it exists to serve: the refusals and the
    # raises are the interesting events.
    #
    # ── A SINK THAT RAISES MUST NOT FAIL THE ACTION ──────────────────────
    #
    # {emit} rescues `StandardError` from the sink and reports it (Rails
    # logger, or `warn` outside Rails) rather than letting it escape. The
    # operator's logging bug is not the assistant's problem: a booking that
    # SUCCEEDED must not come back as a 500 because a Kafka broker was down.
    # The reporting call is itself guarded, so a sink that raises AND a logger
    # that raises still cannot reach the caller.
    #
    # `Exception`s that are NOT `StandardError` — `SignalException`,
    # `NoMemoryError`, `Interrupt` — are deliberately NOT caught. Those are
    # not a logging bug, they are the process dying, and swallowing them would
    # be worse than the failure they announce.
    #
    # The other half of the same guarantee: emission happens AFTER the
    # action's {SessionContext} has closed (see {Executor#audited}), in no
    # transaction of ours, so a slow or wedged sink cannot hold a database
    # transaction open and a failed action's ROLLBACK cannot erase the record
    # of it.
    module AuditSink
      class << self
        # True when this origin has an audit sink at all. Checked before the
        # event is built, so the default costs one nil check per invocation.
        def configured? = !Kiosk.configuration.audit_sink.nil?

        # Hands +event+ to the configured sink.
        #
        # @param event [ActionEvent]
        # @param sink [#call, nil] defaults to the configured sink
        # @return [Boolean] true when a sink received the event without raising
        def emit(event, sink: Kiosk.configuration.audit_sink)
          return false if sink.nil?

          sink.call(event)
          true
        rescue StandardError => e
          report(event, e)
          false
        end

        private

        # A sink failure is REPORTED, never raised and never silent — an audit
        # trail with a hole in it that nothing announces is indistinguishable
        # from an origin nobody called.
        def report(event, error)
          message = "[kiosk-server] audit_sink raised for action " \
                    "#{event.action.inspect}: #{error.class}: #{error.message}"
          logger = defined?(::Rails) && ::Rails.respond_to?(:logger) ? ::Rails.logger : nil
          logger ? logger.error(message) : warn(message)
        rescue StandardError
          # The last line of the guarantee: even a logger that raises must not
          # turn a successful action into a failed request.
          nil
        end
      end
    end
  end
end
