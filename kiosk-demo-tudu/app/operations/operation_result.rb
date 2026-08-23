# frozen_string_literal: true

# WHAT A tudu WRITE OPERATION ANSWERS — one value, or one refusal.
#
# The shared half lives in the gem ({Kiosk::OperationResult}); what stays here
# carries a per-app decision. tudu is the one demo whose HUMAN web UI drives the
# same writes the agent wire drives, and the two present an answer differently —
# `render json:, status:` versus a redirect with a flash. This seam lets ONE
# implementation serve both: an operation renders nothing and knows no HTTP.
class OperationResult < Kiosk::OperationResult
  # The two codes tudu's writes refuse with, and the Rails status symbol each
  # renders as. Deliberately NOT the full wire vocabulary — a code this app never
  # produces has no mapping here, and `fetch` turns a typo into a loud KeyError.
  STATUSES = { "bad_request" => :bad_request, "forbidden" => :forbidden }.freeze
end
