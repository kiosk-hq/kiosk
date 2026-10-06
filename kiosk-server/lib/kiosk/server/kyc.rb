# frozen_string_literal: true

require "json"
require "openssl"
require "kiosk/server/actions"
require "kiosk/server/current_request"
require "kiosk/server/errors"
require "kiosk/server/events"
require "kiosk/server/failure_log"
require "kiosk/server/kyc_verifier"

module Kiosk
  module Server
    # The KYC module: `request_kyc`, the provider's callback, the
    # `kyc_verification` topic and the grants, all keyed on the PERSON (the
    # principal), served against {Kiosk::KycProviders::Base} on every origin
    # with a `kyc_provider`. The operator declares `kyc_claims` and gates with
    # {.require!}.
    module Kyc
      NAME          = "request_kyc"
      TOPIC         = "kyc_verification"
      CALLBACK_PATH = "kyc/callback"
      MAX_OPEN      = 3
      OPEN_WINDOW   = 15 * 60

      REQUEST_HINT = "call `#{NAME}` to verify them: subscribe to the #{TOPIC} topic first, relay the " \
                     "verification_url it returns to your human, and retry once the event arrives".freeze
      ATTEST_HINT  = "submit a KYC attestation carrying them to POST <endpoint>/agents/kyc, then retry".freeze
      CLOSED_HINT  = "verification is not available at this origin and retrying will not help".freeze

      INPUT_SCHEMA = { type: "object", additionalProperties: false, properties: {}, required: [] }.freeze

      OUTPUT_SCHEMA = {
        type: "object", additionalProperties: false,
        properties: {
          request_id:       { type: "string", description: "The id the kyc_verification event for this check carries." },
          verification_url: { type: "string", description: "The page to hand to your human." },
          status:           { const: "pending" },
        },
        required: %w[request_id verification_url status],
      }.freeze

      EVENT_SCHEMA = {
        type: "object", additionalProperties: false,
        properties: {
          request_id: { type: "string" },
          status:     { const: "approved" },
          kyc_jws:    { type: "string", description: "The signed attestation. It is already recorded here; " \
                                                      "you may also submit it to POST <endpoint>/agents/kyc." },
        },
        required: %w[request_id status kyc_jws],
      }.freeze

      class << self
        def provider = Kiosk.configuration.kyc_provider

        def claims = Array(Kiosk.configuration.kyc_claims).map(&:to_s)

        def served!
          return if provider

          raise Errors::ModuleNotServed.new(
            "this operator does not serve the KYC module",
            hint: "no verification can be opened at this origin and retrying will not help — " \
                  "proceed as you would at an operator that offers none.",
          )
        end

        def register!
          Actions.declare(NAME, method(:call), description: description,
                                               input_schema: INPUT_SCHEMA, output_schema: OUTPUT_SCHEMA)
          Events.register(
            name: TOPIC, reach: :principal,
            description: "An identity check you opened with request_kyc was approved and recorded for " \
                         "your human. Retry what you were doing.",
            payload_schema: EVENT_SCHEMA,
            subject_reachable: ->(request_id, identity) { owner_of(request_id) == identity.user_id.to_s },
          )
        end

        def description
          "Start the identity check this origin's gated actions need (#{claims.join(", ")}) for your " \
            "human. Subscribe to the `#{TOPIC}` topic BEFORE calling this, then relay verification_url " \
            "to your human: a KYC provider confirms those facts without passing on any document. Once " \
            "they approve, the event arrives and the facts are recorded; retry the gated action. At " \
            "most #{MAX_OPEN} checks may be open at once; one stops counting when approved, or " \
            "#{OPEN_WINDOW / 60} minutes after it was opened. A check your human refuses sends no event."
        end

        # `request_kyc`.
        def call(_args)
          user_id = CurrentRequest.identity.user_id.to_s
          refuse_over_cap!(user_id)

          opened = begin
            provider.open_verification(subject: user_id, claims: claims,
                                       audience: Kiosk.configuration.kyc_audience.to_s,
                                       callback_url: callback_url)
          rescue Kiosk::KycProviders::Unavailable => e
            FailureLog.report("#{NAME} could not open a verification", e)
            raise Errors::WireError.new(
              "the verification service this operator uses did not open a request",
              code: "action_failed",
              hint: "nothing about your call is wrong. Try `request_kyc` again shortly.",
            )
          end

          execute("INSERT INTO #{table("kyc_requests")} (id, user_id, nonce) VALUES ($1, $2, $3)",
                  opened.fetch(:request_id), user_id, opened.fetch(:nonce))
          { "request_id" => opened.fetch(:request_id), "verification_url" => opened.fetch(:verification_url),
            "status" => "pending" }
        end

        def callback_url
          "#{Kiosk.current_issuer.to_s.chomp("/")}#{Kiosk.configuration.mount_path}/#{CALLBACK_PATH}"
        end

        # The provider's `POST <endpoint>/kyc/callback`: `{request_id, nonce,
        # kyc_jws}`. Verifies the attestation against the open request's
        # principal, records the grant and pushes the event.
        def callback(body)
          body       = body.transform_keys(&:to_s)
          request_id = body["request_id"].to_s
          kyc_jws    = body["kyc_jws"].to_s
          raise Errors.missing_field("request_id") if request_id.empty?
          raise Errors.missing_field("kyc_jws") if kyc_jws.empty?

          row = open_request(request_id)
          raise Errors::NotFound, "no open verification has that request_id" unless row
          unless secure_equal?(row.fetch("nonce"), body["nonce"].to_s)
            raise Errors::Forbidden, "the callback's nonce does not match the verification"
          end

          claims = KycVerifier.verify(raw_jws: kyc_jws, subject: row.fetch("user_id"))
          unless provider.accepts?(claims.transform_keys(&:to_s))
            raise Errors::Forbidden, "the KYC provider's attestation is addressed to another operator"
          end

          approve!(row, claims[:attributes])
          Events.emit(topic: TOPIC, subject: request_id, identity_scope: [row.fetch("user_id")],
                      data: { "request_id" => request_id, "status" => "approved", "kyc_jws" => kyc_jws })
        end

        # Replaces the person's grants with the names `attributes` holds as
        # JSON `true`.
        def grant!(user_id, attributes)
          connection.transaction { write_grants(user_id, attributes) }
        end

        # Does the person hold every one of `names`?
        def granted?(user_id, names = claims)
          names = Array(names).map(&:to_s).uniq
          return false if names.empty?

          quoted = names.map { |name| connection.quote(name) }.join(", ")
          rows = execute("SELECT count(*) AS n FROM #{table("kyc_attributes")} " \
                         "WHERE user_id = $1 AND name IN (#{quoted})", user_id.to_s)
          rows.first.fetch("n").to_i == names.size
        end

        # The gate: raises `kyc_required` unless the calling principal holds
        # every one of `names`.
        def require!(names = claims)
          return if granted?(CurrentRequest.identity.user_id, names)

          raise Errors::KycRequired.new(
            "this action requires the verified attributes #{Array(names).join(", ")}",
            hint: gate_hint,
          )
        end

        # Names only a path this origin serves.
        def gate_hint
          return REQUEST_HINT if provider
          return ATTEST_HINT if Kiosk.configuration.kyc_public_key

          CLOSED_HINT
        end

        private

        def refuse_over_cap!(user_id)
          open = execute("SELECT count(*) AS n FROM #{table("kyc_requests")} WHERE user_id = $1 " \
                         "AND approved_at IS NULL AND created_at > now() - make_interval(secs => $2)",
                         user_id, OPEN_WINDOW).first.fetch("n").to_i
          return if open < MAX_OPEN

          raise Errors::WireError.new(
            "too many verifications are already open for this account",
            code: "quota_exceeded",
            hint: "at most #{MAX_OPEN} may be open at once; one stops counting when your human " \
                  "approves it, and in any case #{OPEN_WINDOW / 60} minutes after it was opened. " \
                  "Wait for the #{TOPIC} event on a page you were already given.",
          )
        end

        def open_request(request_id)
          execute("SELECT id, user_id::text AS user_id, nonce FROM #{table("kyc_requests")} " \
                  "WHERE id = $1 AND approved_at IS NULL", request_id).first
        end

        def owner_of(request_id)
          execute("SELECT user_id::text AS user_id FROM #{table("kyc_requests")} WHERE id = $1",
                  request_id.to_s).first&.fetch("user_id")
        end

        def approve!(row, attributes)
          connection.transaction do
            execute("UPDATE #{table("kyc_requests")} SET approved_at = now() WHERE id = $1", row.fetch("id"))
            write_grants(row.fetch("user_id"), attributes)
          end
        end

        def write_grants(user_id, attributes)
          execute("DELETE FROM #{table("kyc_attributes")} WHERE user_id = $1", user_id.to_s)
          execute("INSERT INTO #{table("kyc_attributes")} (user_id, name) " \
                  "SELECT $2, key FROM jsonb_each($1::jsonb) WHERE value = 'true'::jsonb",
                  JSON.generate(attributes || {}), user_id.to_s)
        end

        def secure_equal?(expected, given)
          !expected.to_s.empty? && expected.bytesize == given.bytesize &&
            OpenSSL.fixed_length_secure_compare(expected, given)
        end

        def table(name) = connection.quote_table_name("#{Kiosk.configuration.schema}.#{name}")

        def execute(sql, *binds) = connection.exec_query(sql, "Kiosk KYC", binds).to_a

        def connection = ::ActiveRecord::Base.lease_connection
      end
    end
  end
end
