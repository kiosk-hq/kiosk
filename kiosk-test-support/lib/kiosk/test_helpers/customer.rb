# frozen_string_literal: true

require "json"
require "jwt"
require "kiosk/test_helpers/assistant"

module Kiosk
  module TestHelpers
    # What the origin answered: what was asked for, or a refusal with its code
    # and a hint about what to do instead.
    class Answer
      def initialize(response) = @response = response

      def ok? = @response.status.between?(200, 299)

      # A problem document's `code`, or an OAuth `error` such as `authorization_pending`.
      def refused?(code) = !ok? && [@response.body["code"], @response.body["error"]].include?(code.to_s)

      def hint = @response.body["hint"].to_s
      def detail = @response.body["detail"].to_s
      def [](key) = @response.body[key.to_s]
      def rows = @response.body
      def header(name) = @response[name]

      # How many proofs of work the assistant solved to be answered.
      def tolls_paid = @response.proofs

      # The proofs of work that pay the toll this refusal demands.
      def solved_toll = Wire.solve(self["challenges"])

      # The `Link` target with `rel="next"`: the rest of a truncated list.
      def next_page = header("link").to_s[/<([^>]*)>\s*;\s*rel="next"/, 1]

      def to_s = "#{@response.status} #{@response.body}"
      alias inspect to_s
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

      # Pays any proof-of-work toll asked for, unless `unpaid:` or carrying its own `proofs:`.
      def asks(query, headers: {}, unpaid: false, proofs: nil, **params)
        headers = headers.merge("Kiosk-PoW" => JSON.generate(proofs)) if proofs
        Answer.new(@assistant.query(principal, name: query.to_s, headers:, pay_tolls: !(unpaid || proofs), **params))
      end

      def does(action, headers: {}, **args) = Answer.new(@assistant.run(principal, name: action.to_s, headers:, **args))

      # Signs intent, cart and payment mandates for `total` cents and pays.
      def pays(total:, scope:, line_items:, currency: "eur")
        Answer.new(@assistant.pay(principal, **@assistant.mandates(principal, total:, scope:, line_items:, currency:)))
      end

      # The answer says whether a card is on file, or carries the page where the person saves one.
      def sets_up_payment = does(:payment_setup)

      # Listens for the check's outcome, then asks for it; the answer carries the page
      # the assistant hands to its person.
      def requests_verification
        listens_for(:kyc_verification)
        does(:request_kyc).tap { @verification = _1["request_id"] if _1.ok? }
      end

      # Whether the origin reports the verification this customer asked for last passed.
      def hears_verification_passed = hears(:kyc_verification, about: @verification)["status"] == "approved"

      # Hands the origin an identity attestation the person obtained elsewhere.
      def presents(attestation) = Answer.new(@assistant.kyc(principal, attestation_jws: attestation))

      # What the origin signed into the credential: whose account, in which role.
      def claims = JWT.decode(principal.token, nil, false).first
      def account = claims["sub"]
      def role = claims["role"]

      def signs_back_in = Answer.new(@assistant.login(principal.rsa_key))

      # This assistant holding the credential a fresh sign-in issues.
      def with_a_fresh_credential = holding(signs_back_in)

      # Redeems the link code a person handed over; the assistant then acts for that person.
      def redeems(link_code) = holding(Answer.new(@assistant.claim(link_code, principal.rsa_key)))

      # Asks to be linked to a person's account; the answer carries the code the person approves.
      def asks_to_be_linked(client_id: "kiosk-story")
        Answer.new(@assistant.device_authorization(client_id:, public_key: principal.rsa_key.public_key.to_pem))
      end

      # Asks once whether the person has approved `request`.
      def polls(request) = Answer.new(@assistant.device_token(request["device_code"], principal.rsa_key))

      # This assistant holding the credential the person granted through `request`.
      def collects(request) = holding(polls(request))

      # News the origin publishes on `topic` from now on reaches the assistant.
      def listens_for(topic)
        @news ||= @assistant.events(principal)
        @news.subscribe(topic.to_s)
      end

      # A connection of its own to the news on `topics`, about `subject`, from after event `since`.
      def follows(*topics, subject: nil, since: nil)
        @assistant.events(principal).tap do |news|
          topics.each { news.subscribe(_1.to_s, **{ subject:, since: }.compact) }
          (@followed ||= []) << news
        end
      end

      # What the origin told the assistant on `topic` (about `subject`, carrying `data`),
      # in the shape the origin publishes for that topic.
      def hears(topic, about: nil, on: @news, **data)
        event = on.await do |heard|
          heard["topic"] == topic.to_s && (about.nil? || heard["subject"] == about.to_s) &&
            data.all? { |key, value| heard.dig("data", key.to_s) == value }
        end
        errors = Assistant::Events.payload_errors(@assistant.schema, [event])
        raise Assistant::Events::Error, "#{origin} published #{event} off its schema: #{errors.join("; ")}" if errors.any?

        event["data"]
      end

      def leaves = [@news, *@followed].compact.each(&:close)

      private

      def holding(answer)
        raise "#{origin} issued no credential: #{answer}" unless answer.ok?

        token = answer["access_token"]
        held  = JWT.decode(token, nil, false).first
        self.class.new(@assistant, principal.with(agent_id: held["agent_id"], user_id: held["sub"], token:))
      end
    end
  end
end
