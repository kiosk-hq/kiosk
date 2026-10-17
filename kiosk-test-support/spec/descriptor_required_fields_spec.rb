# frozen_string_literal: true

# Every published verb declares a `description`, an `input_schema` and an
# `output_schema`. The engine refuses an incomplete declaration at class load;
# this lint reads the origins' sources as text, needs no database and no Rails,
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

    { name: header[/^[ \t]*wire_name[ \t]+['"]([^'"]*)['"]/, 1] || method_name, declared: declared }
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
  # every example below pass while checking nothing. 45 is the fleet's verb
  # count; `>=` lets a new verb pass.
  it 'sees the whole fleet (the lint is not vacuous)' do
    total = origins.values.flatten.sum { |path| DescriptorRequiredFields.verbs_in(File.read(path)).length }
    expect(total).to be >= 45,
                     "the lint resolved only #{total} verbs across #{origins.size} origins — " \
                     'the descriptors moved somewhere it does not read'
  end
end

RSpec.describe 'descriptor required fields per origin' do
  DescriptorRequiredFields.origins.sort.each do |origin, paths|
    it "#{origin}: every verb declares #{DescriptorRequiredFields::MACROS.join(', ')}" do
      missing = DescriptorRequiredFields.missing(origin, paths)

      expect(missing).to be_empty, <<~MSG
        #{missing.size} verb(s) publish an incomplete descriptor:

        #{missing.join("\n")}

        Every verb declares BOTH schemas: `input_schema` is the contract the
        wire coerces and validates arguments against, and `output_schema` is
        the only machine-readable statement of what a call returns. A verb that
        takes nothing still declares the closed empty object.
      MSG
    end
  end
end
