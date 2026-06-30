# frozen_string_literal: true

# Maps a synthetic principal (user_id uuid) to a Stripe Customer ID on the
# provider's Stripe account. Created lazily via the customer_saver lambda
# injected into kiosk-pay-stripe. The gem stays agnostic — it never calls
# this model directly.
class StripeCustomer < ApplicationRecord
end
