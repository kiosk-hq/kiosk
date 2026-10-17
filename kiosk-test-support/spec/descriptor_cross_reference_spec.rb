# frozen_string_literal: true

# Descriptor prose lint. A `description` states semantics only (ADR-0023):
# every param name, type and constraint lives in `input_schema`. This spec reads
# each demo's handler controllers as text (no Rails, no database) and fails when
# a description:
#
# * carries a prose parameter list (`params: …`);
# * names a param that some verb of the same demo declares;
# * routes a param-like token to a verb that does not declare it
#   ("pass X to <verb> as `y`", or "<verb>(x, y)"). This finds a row field
#   that no verb declares, which the second check cannot see.
#
# The first group proves that the extractor still sees every demo's
# descriptors, so an empty result is not a blind one.
require_relative 'support/descriptor_source'
require_relative 'support/descriptor_cross_references'

module DescriptorProseLint
  PARAMS_LIST = /(\(\s*)?\bparams?\s*:/i

  # A handler controller whose comments and string literals hold text that
  # looks like code.
  PHANTOM_CONTROLLER = <<~RB
    class Kiosk::PhantomController < ApplicationController
      kind :action
      description "Edit one listing."
      input_schema type: "object",
                   properties: {
                     listing_id: { type: "string" },
                     # NULLABLE, and the only one of the three that is: an
                     # explicit null clears it. A title cannot be cleared:
                     # a listing with neither is not a listing. An unbalanced
                     # brace { and a lone quote " belong to this prose too.
                     price_text: { type: %w[string null] },
                   },
                   required: ["listing_id"]
      def edit_listing = nil

      kind :query
      description "Ranking is by recency; a # in prose is not a comment."
      input_schema type: "object", properties: { keyword: { type: "string" } }
      def browse_listings = nil
    end
  RB

  module_function

  def census(dir)
    verbs = DescriptorSource.demo_verbs(dir)
    {
      verbs: verbs.size,
      described: verbs.count { |verb| !verb[:description].empty? },
      schemas: verbs.count { |verb| verb[:params].any? }
    }
  end

  def parameter_list_offenders(dir)
    DescriptorSource.demo_verbs(dir).filter_map do |verb|
      match = verb[:description].match(PARAMS_LIST)
      next if match.nil?

      "#{File.basename(dir)} #{verb[:name]}: description writes a parameter list — " \
        "#{verb[:description][[match.begin(0) - 40, 0].max, 120].inspect}"
    end
  end

  def declared_param_offenders(dir)
    verbs    = DescriptorSource.demo_verbs(dir)
    declared = verbs.flat_map { |verb| verb[:params] }.uniq
    names    = verbs.map { |verb| verb[:name] }
    verbs.filter_map do |verb|
      named = DescriptorCrossReferences.declared_params_named(verb[:description], declared, names)
      "#{File.basename(dir)} #{verb[:name]}: description names declared param(s) #{named.inspect}" unless named.empty?
    end
  end

  def cross_reference_failures(dir)
    verbs   = DescriptorSource.demo_verbs(dir)
    by_name = verbs.to_h { |verb| [verb[:name], verb] }
    known   = verbs.flat_map { |verb| verb[:params] }.uniq
    verbs.flat_map do |verb|
      DescriptorCrossReferences.cross_references(verb, by_name, known).flat_map do |ref|
        unresolved(File.basename(dir), verb, by_name.fetch(ref[:target]), ref)
      end
    end
  end

  def unresolved(demo, verb, target, ref)
    (ref[:tokens] - target[:params]).map do |bad|
      "#{demo} #{verb[:name]}: description routes `#{bad}` to #{target[:name]}, " \
        "which declares #{target[:params].inspect} — #{ref[:phrase].inspect}"
    end
  end
end

RSpec.describe 'demo descriptor sources' do
  let(:demo_dirs) { DescriptorSource.demo_dirs }

  it 'finds the demo descriptor sources' do
    expect(demo_dirs).not_to be_empty
  end

  it "actually reads every demo's descriptors (the lint is not vacuous)" do
    seen  = demo_dirs.to_h { |dir| [File.basename(dir), DescriptorProseLint.census(dir)] }
    total = seen.values.sum { |counts| counts[:verbs] }

    expect(total).to be >= 40,
                     "the extractor found only #{total} verb(s) across the fleet #{seen.inspect} — " \
                     'the descriptors have moved somewhere this lint does not read'
    dark = seen.reject { |_demo, counts| counts.values.all?(&:positive?) }
    expect(dark.keys).to be_empty,
                         "these demos yielded no readable descriptors: #{dark.inspect} — verbs, prose or " \
                         'input_schema moved somewhere this lint does not read'
  end

  it 'keeps every handler where the engine loads it' do
    problems = demo_dirs.to_h { |dir| [File.basename(dir), DescriptorSource.stray_handlers(dir)] }
                        .reject { |_demo, files| files.empty? }

    expect(problems).to be_empty,
                        "these files declare verbs outside #{DescriptorSource::HANDLERS_DIR}, so the " \
                        "engine never loads them in development: #{problems.inspect}"
  end
end

RSpec.describe 'DescriptorSource.macro_region' do
  let(:multi_line) do
    <<~RB
      input_schema type: "object",
                   properties: { basket_id: { type: "string" } }
      output_schema type: "array"
    RB
  end

  # The cut is decided by what follows the macro, never by the macro's own shape.
  it 'cuts a macro region at what follows it, not at its own line count' do
    one_line = %(kind :query\ninput_schema type: "object"\ndef ring_up = nil\n)
    trailing = 'input_schema type: "object"'
    last     = multi_line[0, multi_line.index('output_schema')]

    expect(DescriptorSource.macro_region(one_line, 'input_schema')).to eq(%(input_schema type: "object"\n))
    expect(DescriptorSource.macro_region(multi_line, 'input_schema'))
      .to eq(%(input_schema type: "object",\n             properties: { basket_id: { type: "string" } }\n))
    expect(DescriptorSource.macro_region(trailing, 'input_schema')).to eq(trailing)
    expect(DescriptorSource.macro_region(last, 'input_schema')).to eq(last)
  end
end

RSpec.describe 'DescriptorSource.controller_verbs' do
  # A comment contributes no params, and its stray `{` and `"` do not move the
  # end of the body: `price_text`, which follows the comment, still reads. A `#`
  # inside a string literal is content, not the start of a comment.
  it 'reads code out of a descriptor, never comments or string literals (K-1772)' do
    verbs = DescriptorSource.controller_verbs(DescriptorProseLint::PHANTOM_CONTROLLER)

    expect(verbs.map { |verb| verb[:name] }).to eq(%w[edit_listing browse_listings])
    expect(verbs.first[:params]).to eq(%w[listing_id price_text])
    expect(verbs.last[:params]).to eq(%w[keyword])
    expect(verbs.last[:description]).to eq('Ranking is by recency; a # in prose is not a comment.')
  end
end

RSpec.describe 'demo descriptions (ADR-0023)' do
  let(:demo_dirs) { DescriptorSource.demo_dirs }

  it 'no demo description carries a prose parameter list (ADR-0023 §Decision 1/4)' do
    offenders = demo_dirs.flat_map { |dir| DescriptorProseLint.parameter_list_offenders(dir) }

    expect(offenders).to be_empty, <<~MSG
      #{offenders.size} description(s) carry a prose parameter list:

      #{offenders.join("\n")}

      ADR-0023 re-scoped `description` to semantics only and retired the
      `params:` field; restating it in prose is the same duplication one layer
      over. Every name, type and constraint belongs in `input_schema`, and the
      row->input mapping belongs in the two schemas' per-property descriptions.
    MSG
  end

  # A verb name is not an offence: naming the follow-on verb is the sanctioned
  # form. `limit` and `cursor` are reserved names that no verb declares.
  it 'no demo description names a param some verb declares (ADR-0023 §Decision 1)' do
    offenders = demo_dirs.flat_map { |dir| DescriptorProseLint.declared_param_offenders(dir) }

    expect(offenders).to be_empty, <<~MSG
      #{offenders.size} description(s) name a param the schemas already declare:

      #{offenders.join("\n")}

      ADR-0023 §Decision 1 re-scoped `description` to semantics only: it may not
      carry "a param name that the schema also carries". Say what the verb MEANS
      and name the follow-on VERB; leave every argument name to `input_schema`,
      and put a row->argument mapping in the two schemas' per-property
      descriptions, where both ends are declared.
    MSG
  end
end

RSpec.describe 'demo descriptor cross-references' do
  DescriptorSource.demo_dirs.each do |dir|
    demo = File.basename(dir)

    it "#{demo}: every verb description's cross-reference names params the target verb declares" do
      failures = DescriptorProseLint.cross_reference_failures(dir)

      expect(failures).to be_empty, <<~MSG
        #{failures.size} unresolvable descriptor cross-reference(s):

        #{failures.join("\n")}

        A description that names a param the target verb rejects is what the
        assistant sends first. Name the target's REAL input, and state the
        row→input mapping when the row field is spelled differently.
      MSG
    end
  end
end
