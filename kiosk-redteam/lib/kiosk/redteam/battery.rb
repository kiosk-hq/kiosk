# frozen_string_literal: true

require 'json'

module Kiosk
  module Redteam
    # One ledger and one exit status for a red-team run, filing hand-written
    # beats and library Scenarios alike. #report! answers 0 only when at least one
    # attack was blocked, none breached, every attack was tested, and the skips are
    # exactly the expected ones.
    class Battery
      # state is :blocked, :breach, :untested or :skipped.
      Entry = Data.define(:name, :state, :detail)

      def initialize(io: $stdout)
        @io      = io
        @entries = []
      end

      def record(name, blocked, detail = '')
        file(Entry.new(name: name.to_s, state: blocked ? :blocked : :breach, detail: detail.to_s))
      end

      # on_skip: :breach when this origin has the surface, so a skip is a harness defect.
      def scenario(scenario, client:, profile:, on_skip: :skip)
        verdict = scenario.call(client, profile)
        absorb_verdict(scenario.name, verdict, on_skip: on_skip)
      end

      # Runner#run has already printed each line, hence echo: false.
      def absorb(results, on_skip: :skip)
        Array(results).map do |r|
          absorb_verdict(r[:scenario].name, r[:verdict], on_skip: on_skip, echo: false)
        end
      end

      def blocked = @entries.select { |e| e.state == :blocked }

      def breaches = @entries.select { |e| e.state == :breach }

      def skipped = @entries.select { |e| e.state == :skipped }

      def untested = @entries.select { |e| e.state == :untested }

      # Returns the exit status: 0 green, 1 breach, untested attack or no proof, 2 skip set differs from expected_skips.
      def report!(expected_skips: [])
        actual   = skipped.map(&:name).sort
        expected = Array(expected_skips).map(&:to_s).sort

        print_summary
        status = outcome_status
        status = 2 if skips_differ?(actual, expected) && status.zero?
        print_json(actual, status)
        status
      end

      private

      def print_summary
        @io.puts "\n── Summary ──"
        @io.puts(*[blocked, skipped, untested, breaches].flatten.map { line(it, summary: true) })
        @io.puts ''
      end

      def line(entry, summary: false)
        case entry.state
        when :blocked  then "  BLOCKED ✓ #{entry.name}#{" — #{entry.detail}" unless summary || entry.detail.empty?}"
        when :skipped  then "  SKIP    — #{entry.name} (#{entry.detail})"
        when :untested then "  UNTESTED ! #{entry.name} — #{entry.detail}"
        else                "  BREACH  ✗ #{entry.name} — #{entry.detail}"
        end
      end

      # Prints the tally line and answers 0 when every attack was blocked, else 1.
      def outcome_status
        return tally(1, "  #{@entries.size} scenarios, 0 BLOCKED — this run proved NOTHING, which is not a pass.") if blocked.empty?
        unless breaches.empty?
          return tally(1, "#{counts} #{breaches.size} BREACH — FIX REQUIRED",
                       '  BREACH means a real hole in the provider — fix the app, not the scenario.')
        end
        return tally(0, all_blocked_line) if untested.empty?

        tally(1, "#{counts} 0 BREACH — NOT A PASS",
              '  UNTESTED means a setup step or the environment failed, and the attack never reached its gate. ' \
              'Fix the step it names, then run again.')
      end

      def counts = "  #{blocked.size} BLOCKED, #{skipped.size} SKIPPED, #{untested.size} UNTESTED,"

      def all_blocked_line
        "  #{blocked.size} BLOCKED, #{skipped.size} SKIPPED, 0 BREACH — all attacks blocked."
      end

      def tally(status, *lines)
        @io.puts(*lines)
        status
      end

      # Prints the mismatch and answers true when the skip set is not the expected one.
      def skips_differ?(actual, expected)
        return false if actual == expected

        @io.puts ''
        @io.puts '  EXPECTED-APPLICABLE ASSERTION FAILED:'
        @io.puts "    Expected skips: #{expected.inspect}"
        @io.puts "    Actual skips:   #{actual.inspect}"
        @io.puts '  A profile key may have been set to nil, disabling a gate scenario.'
        true
      end

      def print_json(actual, status)
        @io.puts JSON.generate(scenarios: @entries.size, blocked: blocked.size, skipped: actual,
                               breaches: breaches.map(&:name), untested: untested.map(&:name), exit: status)
      end

      def absorb_verdict(name, verdict, on_skip:, echo: true)
        entry = entry_for(name, verdict, on_skip)
        return file(entry) if echo

        @entries << entry
        entry
      end

      def entry_for(name, verdict, on_skip)
        return skip_entry(name, verdict, on_skip) if verdict.skipped
        return Entry.new(name: name, state: :blocked, detail: "HTTP #{verdict.status}") if verdict.blocked
        return Entry.new(name: name, state: :untested, detail: verdict.detail.to_s) if verdict.untested

        Entry.new(name: name, state: :breach, detail: verdict.detail.to_s)
      end

      def skip_entry(name, verdict, on_skip)
        reason = verdict.detail.to_s.delete_prefix('SKIP — ')
        return Entry.new(name: name, state: :skipped, detail: reason) unless on_skip == :breach

        Entry.new(name: name, state: :breach, detail: "SKIPPED, which this origin must never do — #{reason}")
      end

      def file(entry)
        @entries << entry
        @io.puts line(entry)
        entry
      end
    end
  end
end
