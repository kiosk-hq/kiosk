# frozen_string_literal: true

require "json"

module Kiosk
  module Redteam
    # Finds runtime vocabulary (a Ruby class, a PostgreSQL error) in an error
    # body without counting the probe's own echoed value as a leak. A needle is
    # discounted only when it lies wholly inside one span of bytes the probe
    # supplied; discounted needles are reported in Result#note.
    module LeakScan
      Result = Data.define(:leak, :echoed) do
        def leak? = !leak.nil?

        def note
          return "" if echoed.empty?

          " [echoed, not leaked: #{echoed.join(", ")} — these bytes came back " \
            "from the probe's own value, so they are not the runtime speaking]"
        end
      end

      module_function

      # +supplied+ is what the probe put on the wire; nil discounts nothing.
      def scan(body, needles, supplied: nil)
        raw    = body.is_a?(String) ? body : JSON.generate(body)
        spans  = echo_spans(raw, supplied)
        leak   = nil
        echoed = []

        needles.each do |needle|
          next if needle.nil? || needle.empty?

          hits = occurrences(raw, needle)
          next if hits.empty?

          if hits.all? { |at| inside_one_span?(at, needle.length, spans) }
            echoed << needle
          else
            leak ||= needle
          end
        end

        Result.new(leak: leak, echoed: echoed.freeze)
      end

      def leak(body, needles, supplied: nil)
        scan(body, needles, supplied: supplied).leak
      end

      def echo_spans(raw, supplied)
        spellings(supplied).flat_map do |spelling|
          occurrences(raw, spelling).map { |at| [at, at + spelling.length] }
        end
      end

      # Every form a supplied value can take in a serialized body: JSON, the bare
      # JSON string content, Ruby `inspect`, and that `inspect` JSON-escaped.
      def spellings(value, acc = [])
        case value
        when Array then value.each { |element| spellings(element, acc) }
        when Hash  then value.each { |key, element| spellings(key, acc); spellings(element, acc) }
        end

        json = json_fragment(value)
        acc << json if json
        acc << json[1..-2] if json && value.is_a?(String) && json.length > 2
        inspected = value.inspect
        acc << inspected
        acc << json_fragment(inspected)&.slice(1..-2)

        acc.reject! { |spelling| spelling.nil? || spelling.empty? }
        acc.uniq!
        acc
      end

      def json_fragment(value)
        JSON.generate([value])[1..-2]
      rescue StandardError
        nil
      end

      def occurrences(haystack, needle)
        found = []
        at    = 0
        while (at = haystack.index(needle, at))
          found << at
          at += 1
        end
        found
      end

      # One span, not their union: two adjacent echoes must not cover a needle between them.
      def inside_one_span?(at, length, spans)
        finish = at + length
        spans.any? { |from, to| from <= at && finish <= to }
      end
    end
  end
end
