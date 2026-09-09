# frozen_string_literal: true

require "json"

module Kiosk
  module Redteam
    # One ledger, one vocabulary and one exit status for a whole red-team run.
    #
    # A provider's battery is never all framework. Some attacks are generic and
    # arrive as {Scenario} subclasses out of this gem's library; some are about
    # THAT provider's own verbs and its own bugs, and are written by hand
    # against the raw {Wire}. Before this class the two were separate harnesses
    # with separate ledgers, separate printing and separate exit blocks, so a
    # beat written in one shape could not be run by a suite written in the
    # other without being rewritten. A Battery files both, prints both the same
    # way, and answers one exit status for the run.
    #
    #   battery = Kiosk::Redteam::Battery.new
    #
    #   # a hand-written beat against this provider's own surface
    #   status, doc = wire.get_json("/kiosk/my_listings", {}, wire.bearer(bob))
    #   battery.record("CrossTenantRead", status == 200 && !ids.include?(alice_row),
    #                  "Bob's rows #{ids.inspect} exclude Alice's #{alice_row}")
    #
    #   # a generic beat out of the library, in the same ledger
    #   battery.scenario(Kiosk::Redteam::Scenarios::DeviceGrantRoleSelfSelection.new,
    #                    client: client, profile: profile, on_skip: :breach)
    #
    #   # a whole Runner battery, in the same ledger
    #   battery.absorb(runner.run(scenarios))
    #
    #   exit battery.report!(expected_skips: %w[MissingKyc ExpiredKyc])
    #
    # == The three states, and why a skip is not a pass
    #
    # Identical to {Verdict}'s: **blocked** (the provider refused this attack),
    # **breach** (it did not — a real finding), **skipped** (the profile lacks
    # the surface this attack needs, so nothing was exercised). A skip does not
    # count towards the blocked total and does not, by itself, fail the run.
    #
    # == The floor: green requires a proof
    #
    # {#report!} refuses to answer 0 for a run that produced no blocked results
    # at all — the same floor {Runner#all_blocked?} holds, for the same reason.
    # "No breaches" is satisfied by a battery in which nothing happened: skip
    # everything, or record nothing, and a naive `exit 1 if breaches.any?`
    # exits 0 on a gate that proved nothing. That is fail-open on the one gate
    # whose whole job is to fail closed.
    #
    # == The exit statuses
    #
    #   0  every attack that ran was blocked, at least one ran, and the set of
    #      skips is the set that was expected
    #   1  a breach, or no proofs at all
    #   2  the skip set is not the expected one — a profile key that went nil
    #      silently disables a gate scenario, and that must not read as green
    class Battery
      # One filed result.
      #
      # @!attribute name   [String] the beat's name, as printed
      # @!attribute state  [Symbol] :blocked, :breach or :skipped
      # @!attribute detail [String] the human-readable line
      Entry = Data.define(:name, :state, :detail)

      # @param io [IO] where the per-beat and summary lines are printed
      def initialize(io: $stdout)
        @io      = io
        @entries = []
      end

      # @return [Array<Entry>] every filed result, in the order they ran
      attr_reader :entries

      # File a hand-written beat.
      #
      # @param name    [String] the beat's name
      # @param blocked [Boolean] true when the provider refused the attack
      # @param detail  [String] what was demanded and what came back
      # @return [Entry]
      def record(name, blocked, detail = "")
        file(Entry.new(name: name.to_s, state: blocked ? :blocked : :breach, detail: detail.to_s))
      end

      # File a beat that could not be exercised.
      #
      # @param name   [String]
      # @param reason [String] which surface this provider does not have
      # @return [Entry]
      def skip(name, reason)
        file(Entry.new(name: name.to_s, state: :skipped, detail: reason.to_s))
      end

      # Run one {Scenario} and file its verdict.
      #
      # This is the method that makes a library beat runnable from a
      # hand-written suite: the scenario is driven exactly as {Runner} drives
      # it, and its verdict lands in the same ledger as the beats around it.
      #
      # @param scenario [Scenario]
      # @param client   [Client]
      # @param profile  [Profile]
      # @param on_skip  [Symbol] `:skip` files the third state; `:breach` files
      #   a breach instead. Use `:breach` when this origin HAS the surface the
      #   scenario needs, so "could not test" is a defect of the harness rather
      #   than a property of the provider — a silent third state is how a beat
      #   that stopped running goes unnoticed.
      # @return [Entry]
      def scenario(scenario, client:, profile:, on_skip: :skip)
        verdict = scenario.call(client, profile)
        absorb_verdict(scenario.name, verdict, on_skip: on_skip)
      end

      # File the results of a whole {Runner#run}.
      #
      # @param results [Array<Hash{scenario: Scenario, verdict: Verdict}>]
      # @param on_skip [Symbol] see {#scenario}
      # @param echo    [Boolean] false by default: {Runner#run} has already
      #   printed a line per scenario as it went, and printing again would
      #   double every beat in the log.
      # @return [Array<Entry>]
      def absorb(results, on_skip: :skip, echo: false)
        Array(results).map do |r|
          absorb_verdict(r[:scenario].name, r[:verdict], on_skip: on_skip, echo: echo)
        end
      end

      # @return [Array<Entry>] the proofs this run earned
      def blocked = @entries.select { |e| e.state == :blocked }

      # @return [Array<Entry>] the real findings
      def breaches = @entries.select { |e| e.state == :breach }

      # @return [Array<Entry>] the beats that were not exercised
      def skipped = @entries.select { |e| e.state == :skipped }

      # Print the summary and answer the process exit status.
      #
      # Write it `exit battery.report!` — the status is RETURNED rather than
      # exited on, so a suite can print something of its own afterwards, and so
      # this method is testable without forking.
      #
      # @param expected_skips [Array<String>] the names this provider is
      #   expected to skip, because it genuinely lacks those surfaces. A skip
      #   set that differs in either direction answers 2: an unexpected skip is
      #   a gate that silently stopped being tested, and an expected skip that
      #   did NOT happen means this list is stale about a surface the provider
      #   has since grown.
      # @return [Integer] 0, 1 or 2
      def report!(expected_skips: [])
        actual   = skipped.map(&:name).sort
        expected = Array(expected_skips).map(&:to_s).sort

        @io.puts "\n── Summary ──"
        blocked.each  { |e| @io.puts "  BLOCKED ✓ #{e.name}" }
        skipped.each  { |e| @io.puts "  SKIP    — #{e.name} (#{e.detail})" }
        breaches.each { |e| @io.puts "  BREACH  ✗ #{e.name} — #{e.detail}" }
        @io.puts ""

        status = 0
        if blocked.empty?
          @io.puts "  #{@entries.size} scenarios, 0 BLOCKED — this run proved NOTHING, which is not a pass."
          status = 1
        elsif breaches.empty?
          @io.puts "  #{blocked.size} BLOCKED, #{skipped.size} SKIPPED, 0 BREACH — all attacks blocked."
        else
          @io.puts "  #{blocked.size} BLOCKED, #{skipped.size} SKIPPED, #{breaches.size} BREACH — FIX REQUIRED"
          @io.puts "  BREACH means a real hole in the provider — fix the app, not the scenario."
          status = 1
        end

        if actual != expected
          @io.puts ""
          @io.puts "  EXPECTED-APPLICABLE ASSERTION FAILED:"
          @io.puts "    Expected skips: #{expected.inspect}"
          @io.puts "    Actual skips:   #{actual.inspect}"
          @io.puts "  A profile key may have been set to nil, disabling a gate scenario."
          status = 2 if status.zero?
        end

        @io.puts JSON.generate(
          scenarios: @entries.size,
          blocked:   blocked.size,
          skipped:   actual,
          breaches:  breaches.map(&:name),
          exit:      status,
        )
        status
      end

      private

      def absorb_verdict(name, verdict, on_skip:, echo: true)
        entry =
          if verdict.skipped
            reason = verdict.detail.to_s.delete_prefix("SKIP — ")
            if on_skip == :breach
              Entry.new(name: name, state: :breach,
                        detail: "SKIPPED, which this origin must never do — #{reason}")
            else
              Entry.new(name: name, state: :skipped, detail: reason)
            end
          elsif verdict.blocked
            Entry.new(name: name, state: :blocked, detail: "HTTP #{verdict.status}")
          else
            Entry.new(name: name, state: :breach, detail: verdict.detail.to_s)
          end
        echo ? file(entry) : (@entries << entry; entry)
      end

      def file(entry)
        @entries << entry
        case entry.state
        when :blocked then @io.puts "  BLOCKED ✓ #{entry.name}#{" — #{entry.detail}" unless entry.detail.empty?}"
        when :skipped then @io.puts "  SKIP    — #{entry.name} (#{entry.detail})"
        else               @io.puts "  BREACH  ✗ #{entry.name} — #{entry.detail}"
        end
        entry
      end
    end
  end
end
