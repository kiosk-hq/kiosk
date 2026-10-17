# frozen_string_literal: true

# Every verb in the fleet that reaches beyond the calling principal DECLARES it,
# and the set of such verbs is REVIEWED rather than discovered.
#
# §7.2's default is absolute — a verb touches only the
# calling principal's own rows — and any departure is an explicit, published
# property of the verb: `reach :published`, `:consented` or `:role` beside
# `kind`, defaulting to `:principal` when a declaration says nothing. Declaring a
# reach does not make it correct; it makes it REVIEWABLE. This file is where the
# review happens.
#
# WHY AN INVENTORY AND NOT A DERIVATION. Nothing static can decide whether a
# handler that reads `Listing.where(...)` crosses a principal boundary — that is
# a question about the operator's schema, its joins and its intent, and a lint
# that guessed would be wrong in both directions (getgrocery's `catalog` reads
# every caller the same rows and crosses nothing, because a product belongs to
# no principal; philslist's `browse_listings` reads a table with an owner column
# and crosses everything). So the fleet's cross-principal surface is written
# down here, once, with a reason per row, and this spec asserts the sources and
# the list agree IN BOTH DIRECTIONS:
#
#   * a verb that declares a reach and is not on the list fails — a new
#     cross-principal surface cannot appear without somebody adding a line here,
#     which is a line a reviewer sees;
#   * a listed verb that stopped declaring it fails — the declaration cannot be
#     deleted while the behaviour stays;
#   * a listed verb whose declared value CHANGED fails — `consented` quietly
#     becoming `published` is a real weakening (it drops the artefact the
#     operator would have to produce) and must not be a silent one.
#
# WHAT THIS CANNOT CATCH, and do not overtrust it. It reads DECLARATIONS, never
# behaviour: a verb that declares `principal` and leaks anyway is invisible here,
# because the leak is in a WHERE clause and not in a macro. That half is the
# demos' live-wire job — philslist's and tudu's `check:isolation` assert the
# SERVED catalog's reach against what two real principals actually observe, in
# both directions — and this spec is the floor under it: it needs no database
# and no Rails, runs in a second in the gems matrix, and names the offending
# verb instead of failing fifteen minutes into the demos matrix.
#
# A demo declares its verbs in one place: the class-level macro run above each
# `def` in `app/controllers/kiosk/*.rb`.
module VerbReach
  # THE REVIEWED INVENTORY. origin => { verb => reach }. Every entry is a verb
  # that legitimately touches rows belonging to a principal other than the
  # caller; every verb NOT here is `principal`-reach and is held to §7.2's
  # absolute default. The `why` is not decoration — it is the review.
  CROSS_PRINCIPAL = {
    # philslist: the open classifieds board. Rows carry `listings.owner_id`,
    # which IS a user_id, and every authenticated principal sees all of them.
    # `published`, not `consented`: no seller consented to anything, the
    # operator publishes the board because a board is what philslist IS.
    'kiosk-demo-philslist' => {
      'browse_listings' => 'published'
    },
    # tudu: household collaboration. `lists.account_id` and
    # `memberships.account_id` are user_ids; what admits another account's row
    # is a `memberships` row, minted by redeeming a single-use invite a human
    # created. That artefact is why these are `consented` — the stronger claim.
    # `create_list` and `invite` are absent on purpose: both act only on rows
    # the caller already owns.
    'kiosk-demo-tudu' => {
      'my_lists' => 'consented',
      'list_todos' => 'consented',
      'list_members' => 'consented',
      'add_todo' => 'consented',
      'complete_todo' => 'consented',
      'accept_invite' => 'consented',
      'remove_member' => 'consented'
    },
    # stylish: the staff forecast. An `owner` role reads `Appointment.all` —
    # every principal's bookings — and every other role reads its own. Sound
    # only because the role is operator-assigned and never client-requested.
    'kiosk-demo-stylish' => {
      'salon_calendar' => 'role'
    }
  }.freeze

  # The four §7.2 values. A fifth would be a wire change, not a demo change.
  REACHES = %w[principal published consented role].freeze

  DEF = /^[ \t]*def[ \t]+([a-z_][a-zA-Z0-9_]*)[ \t!?(\n]/

  # The text after the last indented `end` of a region: the macro run.
  MACRO_RUN = /(?:\A|^[ \t]+end\n)((?:(?!^[ \t]+end\n).)*)\z/m

  module_function

  # {name:, reach:} per verb of a handler controller. A `def` with no `kind`
  # above it is not a verb.
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
    return unless header.match?(/^[ \t]*kind[ \t]/)

    { name: header[/^[ \t]*wire_name[ \t]+['"]([^'"]*)['"]/, 1] || method_name,
      reach: header[/^[ \t]*reach[ \t]+:([a-z_]+)/, 1] }
  end

  # origin => { verb => declared reach or nil }, read from the sources.
  def declared
    origin_paths.transform_values do |paths|
      paths.sort.flat_map { |path| verbs_in(File.read(path)) }.to_h { |verb| [verb[:name], verb[:reach]] }
    end
  end

  # Handler controller paths per origin: each demo, and the e2e fixtures.
  def origin_paths
    root = File.expand_path('../..', __dir__)
    Dir[File.join(root, 'kiosk-demo-*/app/controllers/kiosk/*.rb')]
      .group_by { |path| path[%r{/(kiosk-demo-[^/]+)/}, 1] }
      .merge('e2e' => Dir[File.join(root, 'e2e/fixtures/*_controller.rb')])
  end

  # The declared verbs whose reach is wider than the calling principal.
  def widened(declared)
    declared.each_with_object({}) do |(origin, verbs), acc|
      wide = verbs.reject { |_name, reach| reach.nil? || reach == 'principal' }
      acc[origin] = wide unless wide.empty?
    end
  end

  def strays(declared)
    declared.flat_map do |origin, verbs|
      verbs.filter_map { |name, reach| "#{origin} #{name}: reach :#{reach}" unless reach.nil? || REACHES.include?(reach) }
    end
  end
end

RSpec.describe 'verb reach declarations' do
  let(:declared) { VerbReach.declared }

  it 'sees the whole fleet (the lint is not vacuous)' do
    expect(declared.values.sum(&:size)).to be >= 45,
                                           "the lint resolved only #{declared.values.sum(&:size)} verbs across " \
                                           "#{declared.size} origins — the declarations moved somewhere it does not read"
  end

  it 'every declared reach is one of the four the spec names' do
    strays = VerbReach.strays(declared)
    expect(strays).to be_empty, "reach is a CLOSED vocabulary (#{VerbReach::REACHES.join(', ')}):\n#{strays.join("\n")}"
  end

  it 'the reviewed inventory is exactly what the fleet declares' do
    actual = VerbReach.widened(declared)

    expect(actual).to eq(VerbReach::CROSS_PRINCIPAL), <<~MSG
      The fleet's cross-principal surface is not the reviewed one.

      declared in the sources: #{actual.inspect}
      reviewed inventory:      #{VerbReach::CROSS_PRINCIPAL.inspect}

      A verb that reaches past the calling principal is a §7.2 departure and is a
      DECISION, not an implementation detail. If a verb gained a reach, add it here
      with the reason it is legitimate and which of the four claims it makes. If one
      lost its declaration while it still crosses a boundary, the fix is the
      declaration, not this list.
    MSG
  end
end

RSpec.describe 'verb reach declarations per reviewed origin' do
  VerbReach::CROSS_PRINCIPAL.each do |origin, verbs|
    it "#{origin}: still declares its cross-principal verbs" do
      expect(VerbReach.declared.fetch(origin, {}).slice(*verbs.keys)).to eq(verbs)
    end
  end
end
