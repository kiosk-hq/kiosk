# frozen_string_literal: true

require 'json'

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
          return '' if echoed.empty?

          " [echoed, not leaked: #{echoed.join(', ')} — these bytes came back " \
            "from the probe's own value, so they are not the runtime speaking]"
        end
      end

      module_function

      # +supplied+ is what the probe put on the wire; nil discounts nothing.
      def scan(body, needles, supplied: nil)
        raw = body.is_a?(String) ? body : JSON.generate(body)
        echoed, leaked = sightings(raw, needles, echo_spans(raw, supplied)).partition(&:last)
        Result.new(leak: leaked.first&.first, echoed: echoed.map(&:first).freeze)
      end

      # [needle, echoed?] for each needle found in +raw+, in needle order.
      def sightings(raw, needles, spans)
        needles.filter_map do |needle|
          next if needle.nil? || needle.empty?

          hits = occurrences(raw, needle)
          [needle, hits.all? { |at| inside_one_span?(at, needle.length, spans) }] unless hits.empty?
        end
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
        nested_values(value).each { |element| spellings(element, acc) }
        acc.concat(own_spellings(value))
        acc.reject! { |spelling| spelling.nil? || spelling.empty? }
        acc.uniq!
        acc
      end

      def nested_values(value)
        case value
        when Array then value
        when Hash  then value.flat_map { |key, element| [key, element] }
        else []
        end
      end

      def own_spellings(value)
        json      = json_fragment(value)
        inspected = value.inspect
        [json, bare_string(json, value), inspected, json_fragment(inspected)&.slice(1..-2)]
      end

      # The JSON string content without its quotes, or nil when +value+ is not a String.
      def bare_string(json, value)
        json[1..-2] if json && value.is_a?(String) && json.length > 2
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
