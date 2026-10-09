# frozen_string_literal: true

require "kiosk/test_helpers/live_server"

module Kiosk
  module TestHelpers
    # What the origin answered: what was asked for, or a refusal with its code
    # and a hint about what to do instead.
    class Answer
      def initialize(response) = @response = response

      def ok? = @response.status.between?(200, 299)
      def refused?(code) = !ok? && @response.body["code"] == code.to_s
      def hint = @response.body["hint"].to_s
      def [](key) = @response.body[key.to_s]
      def rows = @response.body
      def to_s = "#{@response.status} #{@response.body}"
    end

    # Someone's AI assistant at this origin. A demo subclasses it to name what
    # its customers do there: a shopper orders and pays, a rider reserves and rides.
    class Customer
      attr_reader :principal

      def initialize(assistant, principal)
        @assistant = assistant
        @principal = principal
      end

      def origin = @assistant.base_url

      def asks(query, headers: {}, **params) = Answer.new(@assistant.query(principal, name: query.to_s, headers:, **params))
      def does(action, **args) = Answer.new(@assistant.run(principal, name: action.to_s, **args))
      def pays(intent:, cart:) = Answer.new(@assistant.pay(principal, intent:, cart:))

      # The answer carries the page the assistant hands to its person.
      def requests_verification = does(:request_kyc)

      # Hands the origin an identity attestation the person obtained elsewhere.
      def presents(attestation) = Answer.new(@assistant.kyc(principal, attestation_jws: attestation))

      # News the origin publishes on `topic` from now on reaches the assistant.
      def listens_for(topic)
        @news ||= @assistant.events(principal)
        @news.subscribe(topic.to_s)
      end

      # What the origin told the assistant on `topic` about `subject`.
      def hears(topic, about:)
        @news.await { _1["topic"] == topic.to_s && _1["subject"] == about.to_s }["data"]
      end

      def leaves = @news&.close
    end

    # A test that tells a business story: who comes to the origin, what they
    # ask for, what the origin answers and what they learn afterwards.
    module Story
      def self.included(base)
        base.include LiveServer
        base.public_send(base.respond_to?(:teardown) ? :teardown : :after) { @customers&.each(&:leaves) }
      end

      # A newly registered assistant, as `as` (a demo's own Customer subclass).
      def a_customer(as: Customer) = as.new(assistant, register).tap { (@customers ||= []) << _1 }
    end
  end
end
