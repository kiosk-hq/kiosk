# frozen_string_literal: true

require "json"
require "time"

# THE OPERATOR'S AUDIT SINK — what an adopter writes, not what Kiosk ships.
#
# Kiosk keeps no audit trail (K-828, Phil 2026-08-20). It emits one
# `Kiosk::Server::ActionEvent` per action invocation to whatever callable the
# operator sets on `c.audit_sink`, and everything past that seam — where the
# events go, how long they live, what is in them — is the operator's, PII
# included. This class is this harness's answer to that, and it is deliberately
# the most boring one there is: two JSONL files on disk, which `assistant.sh`
# then reads back off a BOOTED origin.
#
# It demonstrates three things the seam promises, and `assistant.sh` asserts
# all three:
#
#   1. THE ARGUMENTS ARRIVE IN FULL. `events` gets `event.to_h` verbatim — the
#      slot the assistant actually sent is in there, because Kiosk did not
#      decide on our behalf that it should not be.
#   2. REDACTING IS ONE CALL. `events-redacted` gets `event.with_arg_types`,
#      which keeps the argument NAMES and replaces every value with its JSON
#      type. Same event, our choice, one method.
#   3. A SINK THAT RAISES DOES NOT FAIL THE ACTION. For one sentinel slot this
#      sink blows up on purpose; the booking it was reporting still succeeds on
#      the wire and still lands in the database.
class DemoAuditSink
  # A slot value this sink deliberately cannot handle. Nothing in Kiosk knows
  # about it — it is a bug we planted in OUR code to prove that our bug stays
  # ours.
  EXPLODING_SLOT = "2030-01-01T00:00:00Z"

  def initialize(path:, redacted_path:)
    @path          = path
    @redacted_path = redacted_path
  end

  def call(event)
    raise "DemoAuditSink is deliberately broken for #{EXPLODING_SLOT}" if
      event.args[:slot] == EXPLODING_SLOT

    append(@path, event)
    append(@redacted_path, event.with_arg_types)
  end

  private

  def append(path, event)
    payload = event.to_h.merge(invoked_at: event.invoked_at.utc.iso8601)
    File.open(path, "a") { |file| file.puts(JSON.generate(payload)) }
  end
end
