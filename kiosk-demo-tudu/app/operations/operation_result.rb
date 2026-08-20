# frozen_string_literal: true

# WHAT A tudu WRITE OPERATION ANSWERS — one value, or one refusal.
#
# The shared half of this object lives in the gem: {Kiosk::OperationResult} in
# kiosk-server holds the constructor and the ok/refused/status trio, and every
# demo subclasses it. It was hand-copied into all seven demos until K-792 and
# T-089 promoted it — the part that repeated had no per-app decision in it,
# and `:per_demo` in bin/check-demo-copies meant nothing compared the copies.
# What stays here is the part that DOES carry a decision: the STATUSES map.
#
# tudu is the only demo whose HUMAN web UI drives the same writes the agent wire
# drives, and the two surfaces present an answer completely differently: the
# wire renders `render json:, status:`, the web UI redirects with a flash. This
# object is the seam that lets ONE implementation of a write serve both without
# either surface's vocabulary leaking into it — an operation renders nothing,
# redirects nothing and knows no HTTP.
class OperationResult < Kiosk::OperationResult
  # The two codes tudu's writes refuse with, and the Rails status symbol each
  # renders as. Deliberately NOT the full fourteen-code wire vocabulary: a code
  # this app never produces has no business having a mapping here, and `fetch`
  # turning a typo into a loud KeyError is the point of writing it out.
  STATUSES = { "bad_request" => :bad_request, "forbidden" => :forbidden }.freeze
end
