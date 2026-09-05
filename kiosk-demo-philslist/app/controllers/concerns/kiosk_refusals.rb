# frozen_string_literal: true

# The HTTP half of philslist's Kiosk handlers: the one place an
# {OperationResult} becomes a response.
#
# WHY A CONCERN when philslist's QUERY half refuses NOTHING and this therefore
# has exactly one includer today. On hoteling, skooti and getgrocery the concern
# is justified by two halves sharing sentences; here it is justified by the
# FLEET. These two renderers are held byte-identical across every migrated demo
# by `bin/check-demo-copies` (rule `:code`), and that gate is the only thing
# standing between "a refusal envelope means the same on all seven origins" and
# a private copy per app that nothing compares. A private `render_operation` in
# the controller would be the same code with no check on it — which is exactly
# how `script/equihash_register.rb` drifted in three of five copies.
#
# What is shared is split the way tudu, hoteling, skooti and getgrocery split it:
# the ANSWER (the refusal and its sentence) is {ListingAccess}/{OperationResult},
# which render nothing and are therefore reachable from the Operations too; what
# is left here is the part that genuinely needs a controller, because it calls
# `render`.
#
# Not a Kiosk mechanism and not shipped by the gem — an ordinary Rails concern
# in the operator's own app, which is the whole point of the mixin design
# — the operator owns the structure.
module KioskRefusals
  extend ActiveSupport::Concern

  private

  # Render whatever an Operation (or a shape guard) answered. Success renders
  # the value as-is — the caller already built it in the exact shape the wire
  # publishes — and a refusal becomes the coded envelope below.
  def render_operation(result)
    return render json: result.value if result.ok?

    render_refusal(result)
  end

  # A plain `render json:, status:` naming a code from the wire's closed
  # vocabulary. Naming it is what lets an assistant branch; the status alone
  # would already imply `bad_request`/`forbidden`, but writing it keeps the
  # answer explicit. A nil hint is dropped, so a refusal with nothing to add
  # carries no empty field — which is what keeps these byte-identical to the
  # envelopes the private renderers produced.
  def render_refusal(result)
    render json: { error: { code: result.code, message: result.message, hint: result.hint }.compact },
           status: result.status
  end
end
