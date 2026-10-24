# frozen_string_literal: true

require 'json'

module Kiosk
  module Redteam
    module Scenarios
      # The calls CallToll makes: unpaid, so that each answer shows whether the toll was asked.
      module TollCalls
        # A setup step did not answer as the probe needs, so the probe did not test the toll.
        class SetupFailed < StandardError; end

        private

        # A new account, after N-1 calls that pass.
        def primed
          @client.register!.tap { prime(it, @every - 1) }
        end

        def prime(principal, calls)
          calls.times do |index|
            answer = ask(principal)
            raise SetupFailed, "call #{index + 1} answered HTTP #{answer.status} #{answer.body.inspect}" unless ok?(answer)
          end
        end

        # The number of the call that met the toll; the toll is paid, so the count is 0 again.
        def calls_to_toll(principal)
          (1..(@every * 20)).each do |number|
            return number.tap { paid_proof(principal, number:) } if tolled?(ask(principal))
          end
          raise SetupFailed, "no call met the toll in #{@every * 20} calls"
        end

        # Pays the toll of the call that met it and answers the proof that paid it.
        def paid_proof(principal, number: @every)
          tolled = ask(principal)
          raise SetupFailed, "call #{number} answered HTTP #{tolled.status}, not the toll" unless tolled?(tolled)

          proof = JSON.generate(TestHelpers::Wire.solve(tolled.body.fetch('challenges')))
          paid = ask(principal, proof:)
          raise SetupFailed, "the paid call answered HTTP #{paid.status} #{paid.body.inspect}" unless ok?(paid)

          proof
        end

        # `calls` calls of `principal`, each from its own thread, all sent before any answer is read.
        def at_once(principal, calls) = Array.new(calls) { Thread.new { ask(principal) } }.map(&:value)

        # nil when the call meets the toll; otherwise what it answered.
        def not_tolled(principal, what)
          answer = ask(principal)
          return nil if tolled?(answer)

          "#{what} answered HTTP #{answer.status} #{answer.body.inspect}, not 402 pow_required"
        end

        def ask(principal, proof: nil, **params)
          headers = proof ? { 'Kiosk-PoW' => proof } : {}
          @client.query(principal, name: @profile.tolled_query, pay_tolls: false, headers:, **params)
        end

        def ok?(answer) = answer.status.between?(200, 299)

        def tolled?(answer) = answer.status == 402 && error_code(answer) == 'pow_required'

        def error_code(answer) = Kiosk::Redteam.error_code(answer)
      end

      # The call toll: an account pays a proof of work on every Nth tolled call.
      # The control brings a new account to N-1 calls and meets `402
      # pow_required` on call N. Each probe brings an account to N-1 calls,
      # tries a known way past the toll, and must still meet the toll.
      class CallToll < Scenario
        include TollCalls

        PROBES = {
          'control' => :control,
          'a new access token' => :new_token,
          'a rotated key' => :rotated_key,
          'a second assistant on the same account' => :second_assistant,
          'a new registration' => :new_registration,
          'calls sent at the same time' => :concurrent_calls,
          'a refused call' => :refused_call,
          'a replayed proof' => :replayed_proof
        }.freeze

        # Calls past N that the concurrent probe sends with the first N.
        EXTRA_CONCURRENT_CALLS = 5

        def initialize
          super(name: 'CallToll')
        end

        def call(client, profile)
          skipped = skip_unless(profile, [[:tolled_calls_per_proof, 'the profile declares no call toll'],
                                          [:tolled_query, 'the profile names no tolled query'],
                                          [:person, 'the profile names no person to link two assistants']])
          return skipped if skipped

          @client = client
          @profile = profile
          @every = profile.tolled_calls_per_proof
          probe_all
        end

        private

        def probe_all
          failures = []
          unevaluated = []
          PROBES.each do |label, probe|
            detail = send(probe)
            failures << "#{label}: #{detail}" if detail
          rescue SetupFailed => e
            unevaluated << "#{label}: #{e.message}"
          end
          verdict = probes_verdict(402, failures, unevaluated)
          verdict.blocked ? blocked_verdict(402, "call #{@every} met 402 pow_required after #{PROBES.keys.join(', ')}") : verdict
        end

        # Call N of a new account meets the toll.
        def control
          not_tolled(primed, "call #{@every} of a new account")
        end

        def new_token
          not_tolled(@client.signed_in(primed), "call #{@every} with a new access token")
        end

        def rotated_key
          rotated = @client.rotate(primed)
          raise SetupFailed, "the rotation answered HTTP #{rotated.status}" unless rotated.is_a?(TestHelpers::Assistant::Principal)

          not_tolled(rotated, "call #{@every} with a rotated key")
        end

        # Two assistants of one person share the count: the second one, linked
        # after the first made N-1 calls, meets the toll on its first call.
        def second_assistant
          person = @profile.person.call
          first = person.links_a_newcomer.principal
          calls_to_toll(first) # sets the count to 0, from whatever the person's account held
          every = calls_to_toll(first) # the interval of this account, which its spend sets
          prime(first, every - 1)
          not_tolled(person.links_a_newcomer.principal, "the first call of a second assistant, after #{every - 1} calls")
        end

        # A new account costs the registration toll.
        def new_registration
          answer = @client.register_raw(pow: :skip)
          return nil if tolled?(answer)

          "a registration with no proof answered HTTP #{answer.status} #{answer.body.inspect}"
        end

        # N + 5 calls of a new account at the same time: exactly N-1 pass.
        def concurrent_calls
          answers = at_once(@client.register!, @every + EXTRA_CONCURRENT_CALLS)
          passed, refused = answers.partition { ok?(it) }
          return nil if passed.size == @every - 1 && refused.all? { tolled?(it) }

          "#{passed.size} of #{answers.size} calls sent at the same time passed, want #{@every - 1}; " \
            "statuses #{answers.map(&:status).tally}"
        end

        # A call refused before the toll does not set the count back.
        def refused_call
          principal = primed
          refused = ask(principal, redteam_unknown_argument: 'x')
          return "a call with an unknown argument answered HTTP #{refused.status}" if ok?(refused)

          not_tolled(principal, "call #{@every}, after a refused call")
        end

        # A proof pays for one call: sent again on a later tolled call, it is refused.
        def replayed_proof
          principal = primed
          proof = paid_proof(principal)
          prime(principal, @every - 1)
          replay = ask(principal, proof:)
          return nil unless ok?(replay)

          "call #{@every} with a proof already spent answered HTTP #{replay.status}"
        end
      end
    end
  end
end
