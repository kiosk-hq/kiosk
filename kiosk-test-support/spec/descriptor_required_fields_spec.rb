# frozen_string_literal: true

# Every published verb declares a `description`, an `input_schema` and an
# `output_schema`; a verb that takes nothing declares the closed empty object.
# The engine refuses a declaration with a missing macro at class load. This
# lint reads the origins' sources as text, needs no database and no Rails,
# and names the offending verb. It also covers a verb whose declaration is
# present but empty, and a controller that `c.handlers` does not name (the
# class never loads, so the engine never checks it).
#
# A demo declares its verbs in one place: the class-level macro run above each
# `def` in `app/controllers/kiosk/*.rb`.
module DescriptorRequiredFields
  MACROS = %w[description input_schema output_schema].freeze

  DEF = /^[ \t]*def[ \t]+([a-z_][a-zA-Z0-9_]*)[ \t!?(\n]/

  # The text after the last indented `end` of a region: the macro run.
  MACRO_RUN = /(?:\A|^[ \t]+end\n)((?:(?!^[ \t]+end\n).)*)\z/m

  module_function

  # {name:, declared: [required macros present]} per verb of a handler
  # controller. A `def` with no macro run above it is not a verb.
  def verbs_in(source)
    previous_end = 0
    source.to_enum(:scan, DEF).filter_map do
      match = Regexp.last_match
      region = source[previous_end...match.begin(0)].to_s
      previous_end = match.end(0)
      verb_from(region[MACRO_RUN, 1] || region, match[1])
    end
  end

  def verb_from(header, method_name)
    declared = MACROS.select { |macro| header.match?(/^[ \t]*#{macro}[ \t(]/) }
    return if declared.empty? && !header.match?(/^[ \t]*wire_name[ \t]/)

    { name: header[/^[ \t]*wire_name[ \t]+['"]([^'"]*)['"]/, 1] || method_name, declared: declared,
      input_schema: header[INPUT_SCHEMA] }
  end

  # The `input_schema` line and the lines indented deeper than it.
  INPUT_SCHEMA = /^([ \t]*)input_schema[ \t(].*\n(?:\1[ \t]+.*\n)*/

  # A verb that takes nothing: its input schema names no property.
  def takes_nothing?(input_schema)
    !input_schema.match?(/\bproperties:/) || input_schema.match?(/\bproperties:[ \t]*\{[ \t]*\}/)
  end

  def verbs_taking_nothing(paths)
    paths.sort.flat_map do |path|
      verbs_in(File.read(path)).select { |verb| verb[:input_schema] && takes_nothing?(verb[:input_schema]) }
    end
  end

  def open_empty_inputs(origin, paths)
    verbs_taking_nothing(paths).filter_map do |verb|
      "#{origin} #{verb[:name]}" unless verb[:input_schema].match?(/\badditionalProperties:[ \t]*false\b/)
    end
  end

  # A property's first line inside an input schema: `name: {`.
  PROPERTY = /^[ \t]*([a-z_]+):[ \t]*\{/

  # §3.8.8: a calendar-day argument says in its own description whose clock it is on.
  NAMES_A_CLOCK = /\b(?:clock|calendar)\b/

  # {verb:, property:, text:} per `format: 'date'` property of every input schema.
  def date_arguments(paths)
    paths.sort.flat_map do |path|
      verbs_in(File.read(path)).flat_map do |verb|
        properties(verb[:input_schema].to_s).filter_map do |name, text|
          { verb: verb[:name], property: name, text: text } if text.match?(/format:[ \t]*'date'/)
        end
      end
    end
  end

  # name => the property's lines, up to the next property.
  def properties(input_schema)
    input_schema.lines.slice_before(PROPERTY).filter_map do |chunk|
      name = chunk.first[PROPERTY, 1]
      [name, chunk.join] if name
    end
  end

  def clockless_dates(origin, paths)
    date_arguments(paths).filter_map do |argument|
      "#{origin} #{argument[:verb]} #{argument[:property]}" unless argument[:text].match?(NAMES_A_CLOCK)
    end
  end

  # Handler controller paths per origin: each demo, and the e2e fixtures.
  def origins
    root = File.expand_path('../..', __dir__)
    found = Dir[File.join(root, 'kiosk-demo-*/app/controllers/kiosk/*.rb')]
            .group_by { |path| path[%r{/(kiosk-demo-[^/]+)/}, 1] }
    found.merge('e2e' => Dir[File.join(root, 'e2e/fixtures/*_controller.rb')])
  end

  def missing(origin, paths)
    paths.sort.flat_map do |path|
      verbs_in(File.read(path)).filter_map do |verb|
        absent = MACROS - verb[:declared]
        "#{origin} #{verb[:name]} (#{File.basename(path)}): missing #{absent.join(', ')}" unless absent.empty?
      end
    end
  end
end

RSpec.describe 'descriptor required fields' do
  let(:origins) { DescriptorRequiredFields.origins }

  it 'finds the handler controllers' do
    expect(origins.keys.sort).to include('e2e', 'kiosk-demo-atablefor', 'kiosk-demo-tudu')
  end

  # The lint is a text matcher, so a reworded or relocated descriptor would make
  # every example below pass while checking nothing. 43 is the fleet's verb
  # count; `>=` lets a new verb pass.
  it 'sees the whole fleet (the lint is not vacuous)' do
    total = origins.values.flatten.sum { |path| DescriptorRequiredFields.verbs_in(File.read(path)).length }
    expect(total).to be >= 43,
                     "the lint resolved only #{total} verbs across #{origins.size} origins — " \
                     'the descriptors moved somewhere it does not read'
  end

  # Fourteen verbs in the fleet take nothing; `>=` lets a new one pass.
  it 'sees the verbs that take nothing (the closed-object check is not vacuous)' do
    total = origins.values.sum { |paths| DescriptorRequiredFields.verbs_taking_nothing(paths).length }
    expect(total).to be >= 14, "the check found only #{total} verbs that take nothing"
  end

  # Eight calendar-day arguments in the fleet; `>=` lets a new one pass.
  it 'sees the calendar-day arguments (the clock check is not vacuous)' do
    total = origins.values.sum { |paths| DescriptorRequiredFields.date_arguments(paths).length }
    expect(total).to be >= 8, "the check found only #{total} format: 'date' arguments"
  end

  describe 'descriptor required fields per origin' do
    DescriptorRequiredFields.origins.sort.each do |origin, paths|
      it "#{origin}: every verb declares #{DescriptorRequiredFields::MACROS.join(', ')}" do
        missing = DescriptorRequiredFields.missing(origin, paths)

        expect(missing).to be_empty, <<~MSG
          #{missing.size} verb(s) publish an incomplete descriptor:

          #{missing.join("\n")}

          Every verb declares BOTH schemas: `input_schema` is the contract the
          engine coerces and validates arguments against, and `output_schema` is
          the only machine-readable statement of what a call returns. A verb that
          takes nothing still declares the closed empty object.
        MSG
      end

      it "#{origin}: every verb that takes nothing declares the closed empty object" do
        open = DescriptorRequiredFields.open_empty_inputs(origin, paths)

        expect(open).to be_empty, <<~MSG
          #{open.size} verb(s) take nothing and accept any argument:

          #{open.join("\n")}

          Declare `input_schema type: 'object', additionalProperties: false, properties: {}`.
        MSG
      end

      it "#{origin}: every calendar-day argument names its clock" do
        clockless = DescriptorRequiredFields.clockless_dates(origin, paths)

        expect(clockless).to be_empty, <<~MSG
          #{clockless.size} format: 'date' argument(s) name no clock:

          #{clockless.join("\n")}

          Say in the argument's own description whose clock or calendar the day is on (§3.8.8).
        MSG
      end
    end
  end
end
