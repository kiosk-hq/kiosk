# frozen_string_literal: true

require "date"
require "time"
require "rack"
require "kiosk/server/errors"

module Kiosk
  module Server
    # Decodes a QUERY's arguments out of the URL query string, per the
    # normative encoding Phil decided in T-070 (option B, 2026-08-17) and
    # narrowed in T-087 (option A, 2026-08-19). That decision is the source of
    # truth for the rule until both specs are rewritten in 0.4; the numbered
    # clauses quoted below are its clauses.
    #
    # ── The rule, and where each half of it lives here ───────────────────
    #
    #   (1) a query's arguments live in the query string, an action's in a
    #       JSON body — so this module is reached from the GET half of the
    #       wire only. {Kiosk::Server::VerbController} is its one caller.
    #   (2) SCALARS are `name=value`; strings UTF-8 percent-encoded,
    #       booleans the literals `true`/`false`, numbers JSON number
    #       literals, dates `YYYY-MM-DD`. Rack unescapes; {#coerce} recovers
    #       the declared type.
    #   (3) ARRAYS OF SCALARS are a repeated BRACKETED name. On the wire that
    #       is spelled PERCENT-ENCODED — `a%5B%5D=v` — because stock Apache
    #       Tomcat answers 400 to a raw `[` in a query string and OAS §C.4.4
    #       requires the encoding; it decodes to `a[]`, and Rack parses both
    #       spellings identically (measured on the shipped Rack 3.2.6), so
    #       serving both costs nothing. A BARE repeated `a=1&a=2` is NOT an
    #       array — Rack keeps only the last value and a server MUST NOT
    #       invent one. See {#fold_declared_arrays} for the ONE exception the
    #       rule does allow, which is type coercion rather than invention.
    #   (4) OBJECTS are `o%5Bk%5D=v`, ONE LEVEL, **SCALAR LEAVES ONLY**.
    #       T-087 dropped the array-of-scalar leaf that T-070-B originally
    #       allowed: `o%5Bk%5D%5B%5D=v` is expressible in no OpenAPI style,
    #       breaks four of the twelve surveyed validators, and had zero
    #       instances in the tree. {#reject_undecodable_shapes!} refuses it.
    #   (5) NOTHING DEEPER IS A QUERY. Two levels of nesting, or an array of
    #       objects, is an ACTION (POST) — refused here with a 400 that says
    #       so, rather than half-decoded.
    #   (6) TYPES COME FROM `input_schema`. Every value arrives from the wire
    #       as a String; the declared type is recovered BEFORE validation and
    #       BEFORE the handler sees it, and a value that will not coerce is
    #       `400 bad_request` NAMING the parameter.
    #   (7) `limit` and `cursor` are RESERVED names — always accepted, never
    #       required to be declared. {RESERVED} carries the types they coerce
    #       to when a verb does not declare them itself.
    #   (8) ABSENT ≠ EMPTY. `?title=` decodes to the empty string under the
    #       key `:title`; a `title` that was never sent has no key at all.
    #       Nothing here fills a missing key in, and nothing drops an empty
    #       one.
    #
    # ── What this module does NOT do ─────────────────────────────────────
    #
    # It does not VALIDATE. Coercion answers "can this string be the declared
    # type at all"; whether the resulting value satisfies the rest of the
    # schema (`enum`, `minimum`, `required`, `additionalProperties`) is
    # {RequestValidation.validate_arguments!}'s job, which runs on the
    # coerced result. The split is deliberate: json_schemer cannot validate a
    # string against `{type: "integer"}`, so coercion has to come first.
    module ArgumentDecoder
      module_function

      # The reserved parameter names (rule 7) and the type each coerces to
      # when the verb's own `input_schema` does not declare it. A verb that
      # DOES declare one wins — its declaration is more specific than this
      # default, and the pagination contract does not forbid a verb from
      # constraining its own `limit`.
      RESERVED = { "limit" => "integer", "cursor" => "string" }.freeze

      # Decode one query string into the argument hash a handler receives.
      #
      # @param query_string [String, nil] `request.query_string` — no leading `?`
      # @param input_schema [Hash, nil] the verb's declared `input_schema`
      #   (symbol- or string-keyed; the macro produces symbols)
      # @return [Hash{Symbol=>Object}] arguments, coerced to their declared types
      # @raise [Errors::BadRequest] naming the parameter, for anything the
      #   rule forbids or that will not coerce
      def decode(query_string, input_schema: nil)
        raw = parse!(query_string)
        raw = fold_declared_arrays(raw, query_string, input_schema)
        reject_undecodable_shapes!(raw)
        coerce_all(raw, input_schema)
      end

      # ── parsing ─────────────────────────────────────────────────────────

      # Rack's own parser, so the percent-encoded and the raw bracket
      # spellings fold into ONE result without a second implementation of
      # bracket parsing. Its three refusals — a name used as both scalar and
      # array (`a=1&a%5B%5D=2`), a nesting depth past the configured limit,
      # and an undecodable percent escape — all descend from
      # `Rack::BadRequest` and all mean the same thing on the wire.
      def parse!(query_string)
        Rack::Utils.parse_nested_query(query_string.to_s)
      rescue ::Rack::BadRequest => e
        raise Errors::BadRequest.new(
          "the query string could not be decoded: #{e.message}",
          hint: SHAPE_HINT,
        )
      end

      # The ONE case where a bare repeated `a=1&a=2` becomes an array, and
      # the reason it is not the "invented array" rule (3) forbids: the verb
      # DECLARED `type: "array"`, so turning the wire's values into one is
      # type coercion, exactly as turning `"4"` into `4` is. Rack has already
      # thrown all but the last value away by then, so the values are
      # re-read from the flat parse — which keys repeats by their literal
      # name and keeps every one of them.
      #
      # Where the schema does NOT declare an array, Rack's last-wins stands
      # and nothing here touches it. Where the wire used the bracketed
      # spelling, Rack has already produced an Array and this is a no-op.
      def fold_declared_arrays(raw, query_string, input_schema)
        flat = nil
        raw.each_with_object({}) do |(name, value), out|
          unless value.is_a?(::String) && declared_type(property_for(name, input_schema)) == "array"
            out[name] = value
            next
          end

          flat ||= ::Rack::Utils.parse_query(query_string.to_s)
          repeated = flat[name]
          out[name] = repeated.nil? ? [value] : Array(repeated)
        end
      end

      # ── the shapes a query cannot carry (rules 4 and 5) ─────────────────

      def reject_undecodable_shapes!(raw)
        raw.each do |name, value|
          case value
          when ::Array then reject_nonscalar_elements!(name, value)
          when ::Hash  then reject_nonscalar_leaves!(name, value)
          end
        end
        raw
      end

      # An array element that is not a scalar means the wire sent
      # `items%5B%5D%5Bsku%5D=milk` — an array of objects, which rule (5)
      # says is an ACTION.
      def reject_nonscalar_elements!(name, value)
        value.each do |element|
          next if element.nil? || element.is_a?(::String)

          raise Errors::BadRequest.new(
            "parameter #{name.inspect} is an array of " \
            "#{element.is_a?(::Hash) ? "objects" : "arrays"}, which a query cannot carry",
            hint: DEPTH_HINT,
          )
        end
      end

      # Two refusals that read alike and mean different things, so they say
      # different things: an ARRAY leaf is the T-087 narrowing (the shape was
      # normative for two days and is not any more), a HASH leaf is rule (5)'s
      # depth limit.
      def reject_nonscalar_leaves!(name, value)
        value.each do |key, leaf|
          next if leaf.nil? || leaf.is_a?(::String)

          if leaf.is_a?(::Array)
            raise Errors::BadRequest.new(
              "parameter #{name.inspect} has an array-valued leaf at #{name}[#{key}]",
              hint: NARROWING_HINT,
            )
          end

          raise Errors::BadRequest.new(
            "parameter #{name.inspect} nests two levels deep at #{name}[#{key}]",
            hint: DEPTH_HINT,
          )
        end
      end

      # ── coercion (rule 6) ───────────────────────────────────────────────

      def coerce_all(raw, input_schema)
        raw.each_with_object({}) do |(name, value), out|
          out[name.to_sym] = coerce(value, property_for(name, input_schema), name.to_s)
        end
      end

      # The declared property for a wire name: the verb's own declaration
      # first, then the reserved-name default (rule 7), then nothing — an
      # undeclared parameter keeps the String the wire sent, and whether it is
      # allowed at all is the validator's question, not this one's.
      def property_for(name, input_schema)
        declared = fetch(fetch(input_schema, :properties), name)
        return declared unless declared.nil?

        reserved = RESERVED[name.to_s]
        reserved && { "type" => reserved }
      end

      def coerce(value, property, path)
        return value if value.nil?

        case declared_type(property)
        when "integer" then to_integer(value, path)
        when "number"  then to_number(value, path)
        when "boolean" then to_boolean(value, path)
        when "string"  then to_string(value, property, path)
        when "array"   then to_array(value, property, path)
        when "object"  then to_object(value, property, path)
        else value
        end
      end

      def to_integer(value, path)
        scalar!(value, "an integer", path)
        Integer(value, 10)
      rescue ::ArgumentError, ::TypeError
        refuse(path, value, "an integer", "a JSON integer literal, e.g. 4")
      end

      def to_number(value, path)
        scalar!(value, "a number", path)
        Float(value)
      rescue ::ArgumentError, ::TypeError
        refuse(path, value, "a number", "a JSON number literal, e.g. 4 or 4.5")
      end

      # Rule (2) names the two literals, so those two are all this accepts:
      # `1`, `on`, `yes` and `TRUE` are Rails idioms, not wire spellings, and
      # accepting them here would put a second boolean grammar on a wire whose
      # whole point is that one is published.
      def to_boolean(value, path)
        scalar!(value, "a boolean", path)
        return true  if value == "true"
        return false if value == "false"

        refuse(path, value, "a boolean", "the literal true or false")
      end

      # A declared string stays a String — JSON has no date type and rule (2)
      # spells dates as strings. What the declared `format` buys is that an
      # unparseable one is refused HERE, naming the parameter, instead of
      # reaching a handler that will `Date.parse` it into a 500 or, worse,
      # answer an invalid filter with a valid-looking empty list (K-717).
      def to_string(value, property, path)
        scalar!(value, "a string", path)
        case fetch(property, :format).to_s
        when "date"      then check_date!(value, path)
        when "date-time" then check_date_time!(value, path)
        end
        value
      end

      def check_date!(value, path)
        parsed = begin
          ::Date.strptime(value, "%Y-%m-%d")
        rescue ::ArgumentError, ::TypeError
          nil
        end
        return if parsed && parsed.strftime("%Y-%m-%d") == value

        refuse(path, value, "a date", "a calendar date as YYYY-MM-DD, e.g. 2026-08-19")
      end

      def check_date_time!(value, path)
        ::Time.iso8601(value)
      rescue ::ArgumentError, ::TypeError
        refuse(path, value, "a timestamp", "an ISO 8601 timestamp, e.g. 2026-08-19T14:00:00Z")
      end

      def to_array(value, property, path)
        refuse(path, value, "an array", "repeated #{path}%5B%5D=… parameters") if value.is_a?(::Hash)

        items = fetch(property, :items)
        Array(value).each_with_index.map { |element, i| coerce(element, items, "#{path}[#{i}]") }
      end

      def to_object(value, property, path)
        unless value.is_a?(::Hash)
          refuse(path, value, "an object", "one #{path}%5Bkey%5D=… parameter per key")
        end

        properties = fetch(property, :properties)
        value.each_with_object({}) do |(key, leaf), out|
          out[key.to_sym] = coerce(leaf, fetch(properties, key), "#{path}[#{key}]")
        end
      end

      # ── helpers ─────────────────────────────────────────────────────────

      # A declaration written by the `input_schema` macro is symbol-keyed; one
      # read back from JSON is string-keyed. Both are the same declaration.
      def fetch(hash, key)
        return nil unless hash.is_a?(::Hash)
        return hash[key.to_sym] if hash.key?(key.to_sym)

        hash[key.to_s]
      end

      # The one type to coerce to. A union (`["integer", "null"]` — the way a
      # nullable parameter is spelled in draft 2020-12) coerces to its first
      # non-null member; an absent `type` means no coercion at all.
      def declared_type(property)
        type = fetch(property, :type)
        case type
        when ::Array then type.map(&:to_s).reject { |t| t == "null" }.first
        when nil     then nil
        else type.to_s
        end
      end

      def scalar!(value, expected, path)
        return unless value.is_a?(::Array) || value.is_a?(::Hash)

        refuse(path, value, expected, "a single #{path}=… parameter")
      end

      def refuse(path, value, expected, spelling)
        raise Errors::BadRequest.new(
          "parameter #{path.inspect} is not #{expected}: #{value.inspect}",
          hint: "#{path} is declared #{expected} — send #{spelling}. " \
                "GET <endpoint>/schema publishes this verb's input_schema.",
        )
      end

      SHAPE_HINT =
        "query arguments are scalars (`a=v`), arrays of scalars (repeated " \
        "`a%5B%5D=v`) or one level of object with scalar leaves " \
        "(`o%5Bk%5D=v`); a name is one shape or the other, never both."

      DEPTH_HINT =
        "a query's arguments are one level deep. A read whose input needs an " \
        "array of objects or two levels of nesting is an ACTION — POST it to " \
        "<endpoint>/<action-name> with a JSON body."

      NARROWING_HINT =
        "an object argument's leaves are SCALARS: `o%5Bk%5D=v`, not " \
        "`o%5Bk%5D%5B%5D=v`. Anything richer is an ACTION (POST)."
    end
  end
end
