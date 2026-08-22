# frozen_string_literal: true

# Every verb in the fleet that reaches beyond the calling principal DECLARES it,
# and the set of such verbs is REVIEWED rather than discovered (K-949, ADR-0028).
#
# WHAT THE SPEC NOW SAYS. §7.2's default is absolute — a verb touches only the
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
#     deleted while the behaviour stays, which is the drift that would put the
#     fleet back where K-949 found it;
#   * a listed verb whose declared value CHANGED fails — `consented` quietly
#     becoming `published` is a real weakening (it drops the artefact the
#     operator would have to produce) and must not be a silent one.
#
# WHAT THIS CANNOT CATCH, and do not overtrust it. It reads DECLARATIONS, never
# behaviour: a verb that declares `principal` and leaks anyway is invisible here,
# because the leak is in a WHERE clause and not in a macro. That half is the
# demos' live-wire job — philslist's and tudu's `demo:isolation` assert the
# SERVED catalog's reach against what two real principals actually observe, in
# both directions — and this spec is the floor under it: it needs no database
# and no Rails, runs in a second in the gems matrix, and names the offending
# verb instead of failing fifteen minutes into the demos matrix.
#
# The extraction is descriptor_required_fields_spec.rb's, for the same reason it
# is that spec's: a demo declares its verbs in ONE place, the class-level macro
# run above each `def` in `app/controllers/kiosk/*.rb`.
RSpec.describe "verb reach declarations" do
  # THE REVIEWED INVENTORY. origin => { verb => reach }. Every entry is a verb
  # that legitimately touches rows belonging to a principal other than the
  # caller; every verb NOT here is `principal`-reach and is held to §7.2's
  # absolute default. The `why` is not decoration — it is the review.
  CROSS_PRINCIPAL = {
    # philslist: the open classifieds board. Rows carry `listings.owner_id`,
    # which IS a user_id, and every authenticated principal sees all of them.
    # `published`, not `consented`: no seller consented to anything, the
    # operator publishes the board because a board is what philslist IS.
    "kiosk-demo-philslist" => {
      "browse_listings" => "published",
    },
    # tudu: household collaboration. `lists.account_id` and
    # `memberships.account_id` are user_ids; what admits another account's row
    # is a `memberships` row, minted by redeeming a single-use invite a human
    # created. That artefact is why these are `consented` — the stronger claim.
    # `create_list` and `invite` are absent on purpose: both act only on rows
    # the caller already owns.
    "kiosk-demo-tudu" => {
      "my_lists"      => "consented",
      "list_todos"    => "consented",
      "list_members"  => "consented",
      "add_todo"      => "consented",
      "complete_todo" => "consented",
      "accept_invite" => "consented",
      "remove_member" => "consented",
    },
    # stylish: the staff forecast. An `owner` role reads `Appointment.all` —
    # every principal's bookings — and every other role reads its own. Sound
    # only because the role is operator-assigned and never client-requested.
    "kiosk-demo-stylish" => {
      "salon_calendar" => "role",
    },
  }.freeze

  # The four §7.2 values. A fifth would be a wire change, not a demo change.
  REACHES = %w[principal published consented role].freeze

  # The macro run above each `def`, per handler controller. A `def` with no run
  # above it is not a verb — the mixin's own rule.
  def self.verbs_in(source)
    out = []
    previous_end = 0
    offset = 0
    while (m = source.match(/^[ \t]*def[ \t]+([a-z_][a-zA-Z0-9_]*)[ \t!?(\n]/, offset))
      method_name  = m[1]
      region       = source[previous_end...m.begin(0)].to_s
      header       = region[/(?:\A|^  end\n)((?:(?!^  end\n).)*)\z/m, 1] || region
      offset       = m.end(0)
      previous_end = offset

      next unless header.match?(/^[ \t]*kind[ \t]/)

      name  = header[/^[ \t]*wire_name[ \t]+"([^"]*)"/, 1] || method_name
      reach = header[/^[ \t]*reach[ \t]+:([a-z_]+)/, 1]
      out << { name: name, reach: reach }
    end
    out
  end

  monorepo_root = File.expand_path("../..", __dir__) # spec/ -> kiosk-test-support/ -> reference/
  origins = Dir[File.join(monorepo_root, "kiosk-demo-*/app/controllers/kiosk/*.rb")]
            .group_by { |path| path[%r{/(kiosk-demo-[^/]+)/}, 1] }
  origins["e2e"] = Dir[File.join(monorepo_root, "e2e/fixtures/*_controller.rb")]

  # origin => { verb => declared reach or nil }, read from the sources.
  declared = origins.transform_values { |paths|
    paths.sort.flat_map { |path| verbs_in(File.read(path)) }
         .to_h { |verb| [verb[:name], verb[:reach]] }
  }

  it "sees the whole fleet (the lint is not vacuous)" do
    expect(declared.values.sum(&:size)).to be >= 52,
                                           "the lint resolved only #{declared.values.sum(&:size)} verbs across " \
                                           "#{declared.size} origins — the declarations moved somewhere it does not read"
  end

  it "every declared reach is one of the four the spec names" do
    strays = declared.flat_map { |origin, verbs|
      verbs.filter_map { |name, reach|
        next if reach.nil? || REACHES.include?(reach)

        "#{origin} #{name}: reach :#{reach}"
      }
    }
    expect(strays).to be_empty, "reach is a CLOSED vocabulary (#{REACHES.join(", ")}):\n#{strays.join("\n")}"
  end

  it "the reviewed inventory is exactly what the fleet declares" do
    actual = declared.each_with_object({}) { |(origin, verbs), acc|
      widened = verbs.reject { |_name, reach| reach.nil? || reach == "principal" }
      acc[origin] = widened unless widened.empty?
    }

    expect(actual).to eq(CROSS_PRINCIPAL), <<~MSG
      The fleet's cross-principal surface is not the reviewed one.

      declared in the sources: #{actual.inspect}
      reviewed inventory:      #{CROSS_PRINCIPAL.inspect}

      A verb that reaches past the calling principal is a §7.2 departure and is a
      DECISION, not an implementation detail. If a verb gained a reach, add it here
      with the reason it is legitimate and which of the four claims it makes. If one
      lost its declaration while it still crosses a boundary, that is the K-949 defect
      itself and the fix is the declaration, not this list.
    MSG
  end

  CROSS_PRINCIPAL.each do |origin, verbs|
    it "#{origin}: still declares its cross-principal verbs" do
      expect(declared.fetch(origin, {}).slice(*verbs.keys)).to eq(verbs)
    end
  end
end
