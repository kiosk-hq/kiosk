# frozen_string_literal: true

# WHAT A skooti WRITE OPERATION ANSWERS — one value, or one refusal.
#
# The shared half lives in the gem: {Kiosk::OperationResult} in kiosk-server
# holds the constructor and the ok/refused/status trio, and every demo
# subclasses it. What stays here is the part that carries a decision: the
# STATUSES map.
class OperationResult < Kiosk::OperationResult
  # The two codes skooti's writes refuse with, and the Rails status symbol each
  # renders as. Deliberately NOT the full wire vocabulary — a code this app never
  # produces has no mapping here, and `fetch` turns a typo into a loud KeyError.
  STATUSES = { "bad_request" => :bad_request, "forbidden" => :forbidden }.freeze
end
