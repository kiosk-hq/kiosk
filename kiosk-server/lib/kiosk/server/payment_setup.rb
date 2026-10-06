# frozen_string_literal: true

require "kiosk/server/actions"
require "kiosk/server/current_request"
require "kiosk/server/events"
require "kiosk/server/failure_log"

module Kiosk
  module Server
    # `payment_setup`: can this principal pay now, or which page must their
    # human finish first. Served against the provider port
    # ({Kiosk::PaymentProviders::Base}) on every origin with a
    # `payment_provider`, so it is the same on every PSP.
    module PaymentSetup
      NAME        = "payment_setup"
      RETURN_PATH = "payment_setup/return"

      DESCRIPTION =
        "Check whether you can pay now. Returns {status: \"ready\"} when `pay` will be accepted. " \
        "Returns {status: \"setup_required\", setup_url: \"…\"} when your human must first open " \
        "setup_url and finish there (for example, save a card); call payment_setup again " \
        "before paying. Call it before `pay`. " \
        "POLLING, where this origin publishes no payment_setup topic: while your human is at " \
        "the page, re-check every ~5 seconds for the first minute, then every ~15 seconds, and " \
        "GIVE UP after about 5 minutes — tell your human the setup is still not finished rather " \
        "than polling indefinitely; they can finish later and you re-check then. " \
        "Relay ONE link: if a later check returns a different url, leave your human on the page " \
        "they already have open unless they say it stopped working."

      INPUT_SCHEMA = { type: "object", additionalProperties: false, properties: {}, required: [] }.freeze

      OUTPUT_SCHEMA = {
        oneOf: [
          { type: "object", additionalProperties: false,
            description: "Nothing to set up — proceed to `pay`.",
            properties: { status: { const: "ready" } },
            required: ["status"] },
          { type: "object", additionalProperties: false,
            description: "Your human must finish the page at setup_url first.",
            properties: {
              status:    { const: "setup_required" },
              setup_url: { type: "string", description: "The page to hand to your human." },
            },
            required: %w[status setup_url] },
        ],
      }.freeze

      TOPIC = {
        name:              NAME,
        reach:             :principal,
        description:       "Your human finished the payment setup. `pay` will now be accepted — " \
                           "no further payment_setup call is needed.",
        payload_schema:    { type: "object", additionalProperties: false,
                             properties: { status: { enum: %w[ready] } },
                             required: %w[status] },
        subject_reachable: ->(subject, identity) { subject.to_s == identity.user_id.to_s },
      }.freeze

      class << self
        def provider = Kiosk.configuration.payment_provider

        # Publishes the action, and the topic when the provider can say whose
        # human came back from the setup page.
        def register!
          Actions.declare(NAME, method(:call), description: DESCRIPTION,
                                               input_schema: INPUT_SCHEMA, output_schema: OUTPUT_SCHEMA)
          Events.register(**TOPIC) if provider.respond_to?(:setup_return_user_id)
        end

        def call(_args)
          user_id = CurrentRequest.identity.user_id
          return { "status" => "ready" } unless provider.setup_required?(user_id: user_id)

          { "status" => "setup_required", "setup_url" => provider.setup_url(user_id: user_id, return_url: return_url) }
        end

        def return_url
          "#{Kiosk.current_issuer.to_s.chomp("/")}#{Kiosk.configuration.mount_path}/#{RETURN_PATH}"
        end

        # The human's browser is back from the setup page. The request is
        # unauthenticated, so it is only a hint: the provider says whose setup
        # it reports, and readiness is asked again before anything is pushed.
        # Never raises — the human is owed the page whatever the PSP does.
        def returned(params)
          return unless Events.fetch(NAME)

          user_id = provider.setup_return_user_id(params).to_s
          return if user_id.empty? || provider.setup_required?(user_id: user_id)

          Events.emit(topic: NAME, subject: user_id, identity_scope: [user_id],
                      data: { "status" => "ready" })
        rescue StandardError => e
          FailureLog.report("#{RETURN_PATH} could not push #{NAME}", e)
        end
      end
    end
  end
end
