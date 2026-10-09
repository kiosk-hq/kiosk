# frozen_string_literal: true

require "json"

module Kiosk
  module Redteam
    # One ledger and one exit status for a red-team run, filing hand-written
    # beats and library Scenarios alike. #report! answers 0 only when at least one
    # attack was blocked, none breached, and the skips are exactly the expected ones.
    class Battery
      # state is :blocked, :breach or :skipped.
      Entry = Data.define(:name, :state, :detail)

      def initialize(io: $stdout)
        @io      = io
        @entries = []
      end

      attr_reader :entries

      def record(name, blocked, detail = "")
        file(Entry.new(name: name.to_s, state: blocked ? :blocked : :breach, detail: detail.to_s))
      end

      def skip(name, reason)
        file(Entry.new(name: name.to_s, state: :skipped, detail: reason.to_s))
      end

      # on_skip: :breach when this origin has the surface, so a skip is a harness defect.
      def scenario(scenario, client:, profile:, on_skip: :skip)
        verdict = scenario.call(client, profile)
        absorb_verdict(scenario.name, verdict, on_skip: on_skip)
      end

      # Runner#run has already printed each line, hence echo: false.
      def absorb(results, on_skip: :skip, echo: false)
        Array(results).map do |r|
          absorb_verdict(r[:scenario].name, r[:verdict], on_skip: on_skip, echo: echo)
        end
      end

      def blocked = @entries.select { |e| e.state == :blocked }

      def breaches = @entries.select { |e| e.state == :breach }

      def skipped = @entries.select { |e| e.state == :skipped }

      # Returns the exit status: 0 green, 1 breach or no proof, 2 skip set differs from expected_skips.
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
