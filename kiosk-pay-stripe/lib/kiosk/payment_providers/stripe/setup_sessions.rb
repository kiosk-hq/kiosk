# frozen_string_literal: true

module Kiosk
  module PaymentProviders
    class Stripe < Base
      # Finds an open setup Checkout Session that `setup_url` can hand out again.
      module SetupSessions
        private

        def outstanding_setup_session(cus_id, success_url:)
          open_sessions = Array(
            ::Stripe::Checkout::Session.list(customer: cus_id, status: 'open', limit: SETUP_SESSION_LIST_LIMIT)&.data
          )
          match = open_sessions.find { |s| reusable_session?(s, success_url) }
          warn_full_page(open_sessions.size) if match.nil? && open_sessions.size >= SETUP_SESSION_LIST_LIMIT
          match
        rescue ::Stripe::StripeError => e
          log_warning("could not list open setup sessions (#{e.class}: #{e.message}); minting a " \
                      'fresh one, so setup_url changes between polls until this clears')
          nil
        end

        def reusable_session?(session, success_url)
          field(session, :mode) == 'setup' &&
            field(session, :success_url) == success_url &&
            !field(session, :url).to_s.empty?
        end

        def warn_full_page(size)
          log_warning("no reusable setup session among a full page of #{size} open " \
                      'Checkout Sessions; minting a fresh one, so setup_url may change between polls')
        end

        def log_warning(text)
          message = "[kiosk-pay-stripe] #{text}"
          logger = ::Rails.logger if defined?(::Rails) && ::Rails.respond_to?(:logger)
          logger ? logger.warn(message) : warn(message)
        end

        # The SDK's StripeObject raises NoMethodError for fields the API omitted.
        def field(obj, name)
          obj.respond_to?(name) ? obj.public_send(name) : nil
        end
      end
    end
  end
end
