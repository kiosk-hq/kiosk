# frozen_string_literal: true

# The page Stripe redirects the human's browser to after they save a card, and
# the operator-side half of the `payment_setup` topic.
#
# == Why a controller and not a static page
#
# The operator ALREADY KNOWS the instant a card is saved: this request is that
# instant. Before this, the assistant discovered it by calling `payment_setup`
# again and again — the skill prescribes roughly 28 polls over five minutes —
# and every one of those re-derives readiness from Stripe, so the cost is 28
# round trips to a third party for one bit that the operator held all along.
#
# == Three things this page must get right, and each is a real hazard
#
# 1. IT IS UNAUTHENTICATED. Anyone may GET it, in any order, with any query
#    string. So it trusts NOTHING in the request: the session id is a claim,
#    and the only thing that turns it into an identity is asking Stripe.
#
# 2. IT RE-DERIVES READINESS rather than believing the redirect. Arriving here
#    means the human's browser followed a link, not that a payment method was
#    attached. The check below is the same `setup_required?` the verb answers.
#
# 3. IT IS A BROWSER REDIRECT, NOT A WEBHOOK, and that is a real limit rather
#    than a detail. A human who closes the tab never lands here, so no event is
#    pushed and the assistant hears nothing. That degrades to exactly one
#    ordinary call to `payment_setup` — the same remedy `truncated: true`
#    prescribes on the stream — and it is why a `checkout.session.completed`
#    webhook remains the durable path rather than this page being the whole
#    story.
class PaymentReturnController < ApplicationController
  def show
    notify_assistant
    render html: page.html_safe, content_type: "text/html" # rubocop:disable Rails/OutputSafety
  end

  private

  # Best effort, and SILENT on failure by design: this page's job is to tell a
  # human their card is saved. A Stripe hiccup while resolving whom to notify
  # must not turn that into an error page — the assistant's fallback is one
  # ordinary `payment_setup` call, which still works.
  def notify_assistant
    session_id = params[:session_id].to_s
    return if session_id.empty?

    customer_id = ::Stripe::Checkout::Session.retrieve(session_id)&.customer
    return if customer_id.to_s.empty?

    user_id = StripeCustomer.find_by(customer_id: customer_id)&.user_id
    return if user_id.to_s.empty?

    # THE READINESS CHECK, not the redirect, is what the event asserts.
    return if Kiosk.configuration.payment_provider.setup_required?(user_id: user_id)

    Kiosk::Server::Events.emit(
      topic: :payment_setup, subject: user_id, identity_scope: [user_id],
      data: { "status" => "ready" },
    )
  rescue StandardError => e
    Rails.logger.warn("[getgrocery] payment/return could not notify: #{e.class}")
    nil
  end

  def page
    <<~HTML
      <!DOCTYPE html><html><head><meta charset='utf-8'><title>Card saved</title></head>
      <body style='font-family:system-ui,sans-serif;text-align:center;padding:64px'>
      <h1>Card saved ✓</h1><p>Your assistant can now pay on your behalf.
      You can close this tab.</p>
      <p style='color:#888;font-size:14px'>getgrocery · Stripe test mode</p>
      </body></html>
    HTML
  end
end
