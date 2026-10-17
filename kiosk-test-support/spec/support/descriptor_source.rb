# frozen_string_literal: true

require_relative 'ruby_source_text'

# Reads a demo's verb descriptors out of its handler controllers as text. A
# descriptor is the run of class-level macros above the `def` that claims it:
#
#   description "…"
#   input_schema type: "object", …, properties: { … }
#   def availability
#
# A method with no macros above it is not a verb.
module DescriptorSource
  # The macros a descriptor run can hold. A macro region ends where the next starts.
  MACRO_NAMES = %w[kind description input_schema output_schema example_params example_row wire_name].freeze

  HANDLERS_DIR = 'app/controllers/kiosk'

  # Pre-filter for {controller_verbs}, which is priced for a handful of files.
  DESCRIPTOR_MACRO = /^[ \t]*(?:description|input_schema)[ \t(]/

  DEF = /^[ \t]*def[ \t]+([a-z_][a-zA-Z0-9_]*)[ \t!?(\n]/

  # The text after the last indented `end` of a region: the macro run.
  MACRO_RUN = /(?:\A|^[ \t]+end\n)((?:(?!^[ \t]+end\n).)*)\z/m

  module_function

  # The string value of a macro written on its own line, as `description '…'`.
  def macro_string_value(header, key)
    match = header.match(/^[ \t]*#{key}[ \t]+(?=['"])/)
    return nil unless match

    RubySourceText.adjacent_strings(header, match.end(0))
  end

  # Property names anywhere in an input_schema, top level and nested (`items[].sku`).
  def schema_property_names(schema_body)
    return [] if schema_body.nil?

    names = []
    pos = 0
    while (match = schema_body.match(/(?<![a-z_])properties:\s*\{/, pos))
      body, = RubySourceText.brace_body_at(schema_body, 'properties', match.begin(0))
      names.concat(RubySourceText.top_level_keys(body)) if body
      pos = match.end(0)
    end
    names
  end

  # The text of ONE macro's argument list: from `<macro>` up to the next macro
  # or `def`. Params are read from `input_schema` only, so an output field is
  # never taken for an accepted param.
  def macro_region(header, macro)
    start = header.index(/^[ \t]*#{macro}[ \t]/)
    return nil if start.nil?

    rest = header[start..]
    first_line_end = rest.index("\n") || rest.length
    following = rest[first_line_end..].to_s
    stop = following.index(/^[ \t]*(?:#{MACRO_NAMES.join('|')})[ \t]|^[ \t]*def[ \t]/)
    stop.nil? ? rest : rest[0, first_line_end + stop]
  end

  # {name:, description:, params: [declared param names]} per verb of a handler controller.
  def controller_verbs(src)
    previous_end = 0
    src.to_enum(:scan, DEF).filter_map do
      match = Regexp.last_match
      region = src[previous_end...match.begin(0)].to_s
      previous_end = match.end(0)
      verb_from(region, match[1])
    end
  end

  def verb_from(region, method_name)
    header      = RubySourceText.without_comments(region[MACRO_RUN, 1] || region)
    description = macro_string_value(header, 'description')
    params      = schema_property_names(macro_region(header, 'input_schema'))
    return if description.nil? && params.empty?

    { name: macro_string_value(header, 'wire_name') || method_name, description: description.to_s, params: params.uniq }
  end

  def handler_files(demo_dir)
    Dir[File.join(demo_dir, HANDLERS_DIR, '**/*.rb')]
  end

  # Files under app/ that declare verbs outside the directory the engine loads.
  def stray_handlers(demo_dir)
    Dir[File.join(demo_dir, 'app/**/*.rb')]
      .select { |path| File.read(path).match?(DESCRIPTOR_MACRO) } - handler_files(demo_dir)
  end

  # Every verb a demo publishes, as ONE list: a cross-reference routinely
  # points across the query/action split.
  def demo_verbs(demo_dir)
    handler_files(demo_dir).flat_map { |path| controller_verbs(File.read(path)) }
  end

  # Every demo directory of the monorepo.
  def demo_dirs
    root = File.expand_path('../../..', __dir__)
    Dir[File.join(root, 'kiosk-demo-*/config/initializers/kiosk.rb')].map { |path| File.expand_path('../../..', path) }
  end
end
