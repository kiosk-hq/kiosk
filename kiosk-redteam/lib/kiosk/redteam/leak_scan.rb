# frozen_string_literal: true

require "json"

module Kiosk
  module Redteam
    # Decide whether a refusal carries the RUNTIME's own vocabulary — without
    # letting the ATTACKER decide the answer.
    #
    # == The defect this exists to remove (T-121)
    #
    # Every hostile-shape beat in this fleet asserts the same third property
    # beside the status and the code: the error body must not name a Ruby class,
    # a PostgreSQL error or a cast. Every one of them asserted it the same way —
    #
    #   leak = NEEDLES.find { |needle| JSON.generate(response.body).include?(needle) }
    #
    # — and every demo answers a bad argument by NAMING the value it got
    # (`neighborhood "Atlantis" is not one this aggregator serves`, `scooter not
    # found: SK-999`, `party_size must be a whole number >= 1 — got "abc"`). So
    # the bytes being scanned are partly the probe's OWN, and a probe whose
    # value spelled `PG::` would have been reported as a BREACH on its own echo,
    # under a runner that tells its reader «A BREACH = a real hole in this demo
    # — fix the app, not the scenario». That instruction would have been exactly
    # wrong. The oracle has to be a function of what the APP said, not of what
    # the attacker sent.
    #
    # == Why this is NOT `raw.gsub(supplied, "")`
    #
    # The obvious repair is to subtract the probe's bytes from the body before
    # searching. It is rejected here, and the reason is the direction it fails
    # in. `gsub` deletes by VALUE, everywhere the value occurs — including
    # inside a sentence the runtime genuinely produced. A probe whose value is
    # `"input syntax"` would erase those bytes out of a real
    # `PG::InvalidTextRepresentation: invalid input syntax for type uuid`,
    # leaving no `invalid input syntax` to find: a real breach reading CLEAN.
    # That is a false NEGATIVE, the one direction a security oracle may never
    # move in — the pre-fix defect only ever produced false POSITIVES.
    #
    # So the scan is POSITIONAL instead. Every occurrence of every spelling the
    # probe's own value can take in the serialized body is recorded as a SPAN,
    # and a needle occurrence is discounted only when it lies wholly inside ONE
    # such span — i.e. only when those exact bytes are bytes the probe supplied,
    # at a place where the probe supplied them. A needle that merely OVERLAPS an
    # echo, or that appears anywhere else in the body, still counts. Under the
    # example above, the genuine `invalid input syntax` starts before the echoed
    # `input syntax` does, so it is not contained by it and is still a leak.
    #
    # == The residual limit, stated rather than hidden
    #
    # If the app genuinely emits a needle AND the probe supplied that exact
    # needle at that exact place, no content-only oracle can tell the two apart;
    # nothing about the bytes distinguishes «you sent me this» from «I said
    # this». That case is therefore REPORTED — {Result#note} names every needle
    # the scan discounted — so a human reading a run sees the judgement being
    # made instead of a silence. It is not swallowed.
    #
    # == Failing loud, not quiet
    #
    # `supplied:` is declared per call, by the beat that knows what it put on
    # the wire. A beat that FORGETS it degrades to the pre-fix oracle exactly:
    # a possible false BREACH, never a missed leak. The safe direction is the
    # default, which is why this is a keyword with a default rather than a
    # channel threaded implicitly through {Response}.
    module LeakScan
      # @!attribute leak   [String, nil] first needle the app itself produced
      # @!attribute echoed [Array<String>] needles present ONLY as the probe's
      #   own echoed bytes, discounted — reported so the discount is visible
      Result = Data.define(:leak, :echoed) do
        # True when the app spoke a needle of its own.
        def leak? = !leak.nil?

        # Human-readable tail for a beat's failure/detail line. Empty when
        # nothing was discounted, so unaffected beats print exactly as before.
        def note
          return "" if echoed.empty?

          " [echoed, not leaked: #{echoed.join(", ")} — these bytes came back " \
            "from the probe's own value, so they are not the runtime speaking]"
        end
      end

      module_function

      # Scan a response body for needles the RUNTIME produced.
      #
      # @param body [Hash, Array, String, nil] the parsed response body (or the
      #   already-serialized JSON string)
      # @param needles [Array<String>] the leak vocabulary this beat forbids
      # @param supplied [Object] what the probe itself put on the wire for this
      #   call — normally the arguments Hash (`{ booking_id: junk }`), which is
      #   walked recursively so every leaf value and every container spelling is
      #   covered. `nil` means "declared nothing", which is the pre-fix oracle.
      # @return [Result]
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

      # The first needle the runtime produced, or nil — the drop-in replacement
      # for `needles.find { |n| JSON.generate(body).include?(n) }`.
      #
      # @return [String, nil]
      def leak(body, needles, supplied: nil)
        scan(body, needles, supplied: supplied).leak
      end

      # ── internal ──────────────────────────────────────────────────────────

      # Byte ranges of `raw` that are the probe's own value echoed back.
      #
      # @return [Array<Array(Integer, Integer)>] half-open [from, to) pairs
      def echo_spans(raw, supplied)
        spellings(supplied).flat_map do |spelling|
          occurrences(raw, spelling).map { |at| [at, at + spelling.length] }
        end
      end

      # Every literal form a supplied value can take inside a serialized body.
      #
      # FOUR forms, because a demo may render the value any of these ways and
      # the span has to be found whichever it chose: the JSON serialization
      # (`"abc"`), a JSON string's ESCAPED CONTENT without its quotes (`abc` —
      # what an interpolated `#{value}` becomes), Ruby's `inspect` (`"abc"`
      # with the quotes as literal characters, what `#{value.inspect}` writes),
      # and that `inspect` re-escaped for JSON (`\"abc\"`, how it actually
      # appears in the generated document).
      #
      # Containers are walked, and BOTH the container and each leaf contribute:
      # a demo that echoes `item.inspect` prints the whole Hash, one that
      # echoes `item[:qty].inspect` prints one leaf, and neither spelling can
      # be derived from the other.
      #
      # A spelling shorter than a needle can never CONTAIN one, so no length
      # floor is needed — containment does that work, and it is what keeps a
      # one-character probe value from masking anything.
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

      # `value` as it would be serialized INSIDE a JSON document, or nil when it
      # is not serializable at all (a probe may hold anything).
      def json_fragment(value)
        JSON.generate([value])[1..-2]
      rescue StandardError
        nil
      end

      # Every index at which `needle` occurs in `haystack` (overlaps included).
      def occurrences(haystack, needle)
        found = []
        at    = 0
        while (at = haystack.index(needle, at))
          found << at
          at += 1
        end
        found
      end

      # Is [at, at+length) wholly inside ONE span?
      #
      # ONE, deliberately — not the union. Two adjacent echoes must not be able
      # to cover between them a needle neither of them contains; requiring a
      # single contiguous run of the probe's own bytes is the strict reading,
      # and strict here means erring towards CALLING a leak.
      def inside_one_span?(at, length, spans)
        finish = at + length
        spans.any? { |from, to| from <= at && finish <= to }
      end
    end
  end
end
