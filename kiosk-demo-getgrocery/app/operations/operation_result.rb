# frozen_string_literal: true

# WHAT A getgrocery WRITE OPERATION ANSWERS — one value, or one refusal.
#
# The shared half of this object lives in the gem: {Kiosk::OperationResult} in
# kiosk-server holds the constructor and the ok/refused/status trio, and every
# demo subclasses it. It was hand-copied into all seven demos until K-792 and
# T-089 promoted it — the part that repeated had no per-app decision in it,
# and `:per_demo` in bin/check-demo-copies meant nothing compared the copies.
# What stays here is the part that DOES carry a decision: the STATUSES map.
#
# On getgrocery the seam earns its keep twice over. `create_order` is a five-gate
# chain that ends in a transaction with a row lock in it, and a `render` in the
# middle of that is what every earlier slice had to reason about. And this demo
# has a SECOND surface: the operator's back office at GET /admin/orders reads the
# same "is this order paid" fact the wire publishes — so the containment that
# answers it had to become one thing both call (it is
# {Order.settling}), which is only expressible once the write half has stopped
# being a block in an initializer.
class OperationResult < Kiosk::OperationResult
  # The codes getgrocery's verbs refuse with, and the Rails status symbol each
  # renders as. Deliberately NOT the full fourteen-code wire vocabulary: a code
  # this app never produces has no business having a mapping here, and `fetch`
  # turning a typo into a loud KeyError is the point of writing it out. tudu's
  # copy lists two and hoteling's four; getgrocery's four are the three its
  # handlers raised as `Errors::` classes before the conversion (bad_request,
  # forbidden, not_found) plus `kyc_required` — the alcohol age gate.
  # `kyc_required` and `forbidden` are BOTH 403, so the code is not derivable
  # from the status: it is the only thing that tells an assistant "go and get
  # attested" apart from "this is not yours".
  STATUSES = {
    "bad_request"  => :bad_request,
    "forbidden"    => :forbidden,
    "not_found"    => :not_found,
    "kyc_required" => :forbidden,
  }.freeze
end
