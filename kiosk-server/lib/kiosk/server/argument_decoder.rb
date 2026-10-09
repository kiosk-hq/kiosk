# frozen_string_literal: true

require "date"
require "time"
require "rack"
require "kiosk/server/errors"

module Kiosk
  module Server
    # Decodes a query's arguments from the URL query string and coerces them
    # to the types `input_schema` declares. Validation runs afterwards, on the
    # coerced result (RequestValidation).
    module ArgumentDecoder
      module_function

      # Reserved names and their types when a verb does not declare them itself.
      RESERVED = { "limit" => "integer", "cursor" => "string" }.freeze

      # @param input_schema [Hash, nil] the verb's `input_schema`, symbol- or string-keyed
      # @raise [Errors::BadRequest] naming the parameter
      def decode(query_string, input_schema: nil)
        raw = parse!(query_string)
        raw = fold_declared_arrays(raw, query_string, input_schema)
        reject_undecodable_shapes!(raw)
        coerce_all(raw, input_schema)
      end

      def parse!(query_string)
        Rack::Utils.parse_nested_query(query_string.to_s)
      rescue ::Rack::BadRequest
        raise Errors::BadRequest.new(
          "the query string could not be decoded",
          hint: SHAPE_HINT,
        )
      end

      # A bare repeated `a=1&a=2` becomes an array only when the verb declares
      # `type: "array"`; otherwise Rack's last value wins.
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

      def reject_undecodable_shapes!(raw)
        raw.each do |name, value|
          case value
          when ::Array then reject_nonscalar_elements!(name, value)
          when ::Hash  then reject_nonscalar_leaves!(name, value)
          end
        end
        raw
      end

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

      # An array leaf is the scalar-leaves rule; a hash leaf is the depth limit.
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

      def coerce_all(raw, input_schema)
        raw.each_with_object({}) do |(name, value), out|
          out[name.to_sym] = coerce(value, property_for(name, input_schema), name.to_s)
        end
      end

      # An undeclared parameter stays a String; whether it is allowed is the validator's call.
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

      # Only the literals `true` and `false`.
      def to_boolean(value, path)
        scalar!(value, "a boolean", path)
        return true  if value == "true"
        return false if value == "false"

        refuse(path, value, "a boolean", "the literal true or false")
      end

      # A string stays a String; a declared `format` is checked here.
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

        refuse(path, value, "a date", FORMAT_SPELLINGS["date"])
      end

      def check_date_time!(value, path)
        ::Time.iso8601(value)
      rescue ::ArgumentError, ::TypeError
        refuse(path, value, "a timestamp", FORMAT_SPELLINGS["date-time"])
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

      def fetch(hash, key)
        return nil unless hash.is_a?(::Hash)
        return hash[key.to_sym] if hash.key?(key.to_sym)

        hash[key.to_s]
      end

      # A nullable union like `["integer", "null"]` coerces to its non-null member.
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

      # What a caller has to send for each string `format` the wire reads.
      FORMAT_SPELLINGS = {
        "date"      => "a calendar date as YYYY-MM-DD, e.g. 2026-08-19",
        "date-time" => "an ISO 8601 timestamp, e.g. 2026-08-19T14:00:00Z",
      }.freeze

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
