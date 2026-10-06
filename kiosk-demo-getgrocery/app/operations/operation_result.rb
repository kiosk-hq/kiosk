# frozen_string_literal: true

# What a getgrocery write Operation answers — one value, or one refusal.
#
# The shared half lives in the gem: {Kiosk::OperationResult} in kiosk-server
# holds the constructor and the ok/refused/status trio. What stays here is the
# part that carries a per-app decision: the STATUSES map.
class OperationResult < Kiosk::OperationResult
  # The two codes getgrocery's writes refuse with, and the Rails status symbol each
  # renders as. Deliberately NOT the full wire vocabulary — a code this app never
  # produces has no mapping here, and `fetch` turns a typo into a loud KeyError.
  STATUSES = { "bad_request" => :bad_request, "forbidden" => :forbidden }.freeze
end
