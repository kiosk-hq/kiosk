# frozen_string_literal: true

require "openssl"
require "kiosk/test_helpers/customer"
require "kiosk/test_helpers/live_server"

module Kiosk
  module TestHelpers
    autoload :Person, "kiosk/test_helpers/person"

    # A test that tells a business story: who comes to the origin, what they
    # ask for, what the origin answers and what they learn afterwards.
    module Story
      def self.included(base)
        base.include LiveServer
        base.public_send(base.respond_to?(:teardown) ? :teardown : :after) { @assistant&.disconnect }
      end

      # A newly registered assistant, as `as` (a demo's own Customer subclass).
      def a_customer(as: Customer) = as.new(assistant, register)

      # An assistant holding a key and no account here yet.
      def a_newcomer(as: Customer)
        as.new(assistant, Assistant::Principal.new(agent_id: nil, user_id: nil, token: nil, rsa_key: OpenSSL::PKey::RSA.generate(2048)))
      end

      # Someone with an account on the operator's site, signed in there.
      def a_person(email:, password:) = Person.new(live_url, email:, password:)

      # What the origin publishes at `path` to anyone, with no credential.
      def published(path)
        status, body = assistant.wire.get_json(path)
        raise "GET #{path} with no credential answered #{status}" unless status == 200

        body
      end
    end
  end
end
