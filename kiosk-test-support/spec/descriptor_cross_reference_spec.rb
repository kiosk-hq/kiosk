# frozen_string_literal: true

# Descriptor prose lint — the ADR-0023 prohibition, plus the K-494
# cross-reference check for the prose that has not been rewritten yet.
#
# A verb description routinely tells the assistant where a row's fields go
# next — "Pass restaurant_id + restaurant_table_id + date + time to
# book_table", "pass it to cancel_booking as `booking_id`". That sentence IS
# the contract the assistant reads first, and when it names a param the target
# verb does not accept, the assistant sends exactly what we told it to and gets
# a 400 (K-494, observed on the live wire: atablefor's `availability` said
# "seating_date", which is the ROW field name, while book_table's input is
# `date`).
#
# ── WHAT ADR-0023 DID TO THIS FILE (K-846) ────────────────────────────────
# ADR-0023 retired the premise. `description` is semantics only; every name,
# type and constraint lives in `input_schema`/`output_schema`, and its
# §Consequences says outright that "the per-description lint K-494 asked for is
# superseded by a structural property … prose stops naming params at all".
# Checking that a param named in prose EXISTS is checking the correctness of a
# construct the ADR forbids — green on a violation, by construction.
#
# So this file grows the PROHIBITION and keeps the cross-reference resolution
# only for as long as the prose it reads survives:
#
#   * the prohibition (below) fails any description carrying a prose parameter
#     list — the `params:` shape ADR-0023 §Decision 4 retired, restated in
#     prose. Fleet-clean at head.
#   * the cross-reference examples still resolve whatever "pass X to <verb> as
#     `y`" clauses remain, so the K-494 class cannot regress while they do.
#     They are green-and-EMPTY once a demo is rewritten, which is correct: an
#     ADR-0023 description has nothing to resolve. K-852 rewrites the remaining
#     six demos and widens the prohibition to every param name.
#
# Note what is NOT asserted any more: that a demo still HAS cross-references.
# That floor (one per demo, twelve across the fleet) made ADR-0023 conformance
# a test failure — rewriting a demo's prose correctly turned this suite red.
# The property it was really guarding is that the lint can still SEE the
# descriptors, and that is now asserted directly, on the verbs it extracts.
#
# It reads the sources as TEXT (no Rails boot, no DB), the same technique as
# skill_pin_spec.rb. A demo declares its verbs in ONE place — the class-level
# macros of the handler controllers under `app/controllers/kiosk/` (T-053 /
# T-057, and since T-081 the only way in). A cross-reference points across the
# query/action controller split, so a demo's controllers are read as ONE list.
#
# Two cross-reference shapes are recognised:
#
#   A. prose  — "<pass|send|…> <span> to <verb>[ / <verb>]…[ as <tail>]"
#   B. call   — "<verb>(arg, arg, …)"
#
# From the span/tail/arglist it collects PARAM-LIKE tokens (a token containing
# an underscore, or one that is a declared param of some verb in the same
# demo) and requires each to be declared by the target verb. Tokens that are
# plainly prose ("it", "both", "the id") are not param-like and are ignored —
# the lint is about names that LOOK like params and do not resolve.
RSpec.describe "demo descriptor cross-references" do
  # ── Source-text extraction ────────────────────────────────────────────────
  module DescriptorSource
    module_function

    # Same, for the MACRO spelling a handler controller uses: `description "…"`
    # on its own line, no colon. Anchored to the start of a line so a
    # `description:` INSIDE an input_schema property, and the word in a comment,
    # are both ignored.
    def macro_string_value(header, key)
      m = header.match(/^[ \t]*#{key}[ \t]+(?=")/)
      return nil unless m

      adjacent_strings(header, m.end(0))
    end

    # One or more adjacent double-quoted literals starting at `i`, joined.
    def adjacent_strings(text, i)
      parts = []
      loop do
        i += 1 while i < text.length && (text[i].match?(/\s/) || text[i] == "\\")
        break unless text[i] == '"'

        i += 1
        buf = +""
        while i < text.length
          case text[i]
          when "\\" then buf << text[i + 1]; i += 2
          when '"' then i += 1; break
          else buf << text[i]; i += 1
          end
        end
        parts << buf
      end
      parts.empty? ? nil : parts.join
    end

    # The body of the first `key: { … }` at or after `from`, brace-balanced and
    # string-aware. Returns [body, offset just past the closing brace] so a
    # caller can keep scanning — an empty body ("properties: {}") must still
    # advance.
    def brace_body_at(text, key, from = 0)
      m = text.match(/(?<![a-z_])#{key}:\s*\{/, from)
      return nil unless m

      start = m.end(0)
      i = start
      depth = 1
      in_str = false
      while i < text.length && depth.positive?
        ch = text[i]
        if in_str
          if ch == "\\" then i += 1
          elsif ch == '"' then in_str = false
          end
        else
          case ch
          when '"' then in_str = true
          when "{", "[" then depth += 1
          when "}", "]" then depth -= 1
          end
        end
        i += 1
      end
      [text[start...(i - 1)], i]
    end

    # `key:` symbol keys at brace/bracket depth 0 of a hash body.
    def top_level_keys(body)
      return [] if body.nil?

      keys = []
      depth = 0
      i = 0
      in_str = false
      while i < body.length
        ch = body[i]
        if in_str
          if ch == "\\" then i += 1
          elsif ch == '"' then in_str = false
          end
        else
          case ch
          when '"' then in_str = true
          when "{", "[" then depth += 1
          when "}", "]" then depth -= 1
          else
            if depth.zero? && (m = body[i..].match(/\A([a-z_][a-z0-9_]*):(?!:)/)) &&
               (i.zero? || !body[i - 1].match?(/[A-Za-z0-9_:]/))
              keys << m[1]
              i += m[0].length - 1
            end
          end
        end
        i += 1
      end
      keys
    end

    # Property names anywhere in an input_schema (top level AND nested, e.g.
    # `items[].sku`), so a cross-reference naming a nested field still
    # resolves.
    def schema_property_names(schema_body)
      return [] if schema_body.nil?

      names = []
      pos = 0
      while (found = brace_body_at(schema_body, "properties", pos))
        names.concat(top_level_keys(found.first))
        pos = found.last
      end
      names
    end

    # The text of ONE macro's argument list — everything from `<macro>` up to
    # the next class-level macro or the `def` that claims the run.
    #
    # THE LINT IS ABOUT INPUTS, and since T-068 slice 3 every verb also
    # declares an `output_schema` with `properties:` of its own. Scanning the
    # whole macro run for `properties:` would take a verb's RESULT fields for
    # its accepted params, which breaks the lint in both directions: a
    # cross-reference naming a result field would wrongly resolve, and a prose
    # word that happens to be a result field name ("pass the id to
    # book_appointment") would wrongly become param-like and fail. So the
    # params are read out of the `input_schema` macro and nowhere else.
    MACRO_NAMES = %w[description input_schema output_schema example_params example_row wire_name].freeze

    def macro_region(header, macro)
      start = header.index(/^[ \t]*#{macro}[ \t]/)
      return nil if start.nil?

      rest  = header[start..]
      body  = rest[/\A[^\n]*\n/] ? rest : rest
      # The next macro at line start, after this one's first line.
      first_line_end = rest.index("\n") || rest.length
      following = rest[first_line_end..].to_s
      stop = following.index(/^[ \t]*(?:#{MACRO_NAMES.join("|")})[ \t]|^[ \t]*def[ \t]/)
      stop.nil? ? body : rest[0, first_line_end + stop]
    end

    # {name:, description:, params: [declared param names]} per verb, read out
    # of a HANDLER CONTROLLER (T-053 mixin / T-057). The descriptor is a run of
    # class-level macros that the NEXT `def` claims:
    #
    #   description "…"
    #   input_schema type: "object", …, properties: { … }
    #   def availability
    #
    # So a "header" is the macro run immediately above a `def`, and a method
    # with no macros above it is not a verb — the mixin's own rule, which is
    # what keeps the private `render_*` refusal helpers out of the catalog.
    #
    # The macro run is isolated by cutting at the previous method's `  end`
    # (two-space `end` at method depth, the convention every handler controller
    # in this repo follows). If that convention ever breaks, the header grows to
    # include the previous method's body — harmless for extraction, and the
    # non-vacuity example below is what would notice a real regression.
    def controller_verbs(src)
      out = []
      offset = 0
      previous_end = 0
      while (m = src.match(/^[ \t]*def[ \t]+([a-z_][a-zA-Z0-9_]*)[ \t!?(\n]/, offset))
        method_name = m[1]
        region      = src[previous_end...m.begin(0)].to_s
        # Everything after the previous method's terminator — the macro run.
        header       = region[/(?:\A|^  end\n)((?:(?!^  end\n).)*)\z/m, 1] || region
        offset       = m.end(0)
        previous_end = offset

        description  = macro_string_value(header, "description")
        schema_props = schema_property_names(macro_region(header, "input_schema"))
        next if description.nil? && schema_props.empty?

        name = macro_string_value(header, "wire_name") || method_name
        out << { name: name, description: description.to_s, params: schema_props.uniq }
      end
      out
    end

    # Every verb a demo publishes: the handler controllers under
    # app/controllers/kiosk/. ONE list per demo, because a cross-reference
    # routinely points across the query/action split — atablefor's
    # `availability` (a query controller) names `book_table` (an action
    # controller), which is exactly the K-494 drift this lint exists for.
    def demo_verbs(demo_dir)
      Dir[File.join(demo_dir, "app/controllers/kiosk/**/*.rb")].sort
         .flat_map { |path| controller_verbs(File.read(path)) }
    end
  end

  # ── Cross-reference detection ─────────────────────────────────────────────

  # Verbs that introduce a "route this value onward" clause.
  TRIGGER = /\b(?:pass|passing|send|supply|provide|give|echo)\b/i

  # Identifiers that read like params but never are: Postgres/GUC helpers the
  # descriptions cite by name.
  NON_PARAM_TOKENS = %w[current_user_id current_agent_id].freeze

  # Pull identifier tokens out of a prose span, dropping method-call shapes
  # (`kiosk.current_user_id`) and anything that is not param-like.
  def self.param_like(span, known_params, verb_names)
    tokens = []
    span.scan(/(?<![.\w])([a-z][a-z0-9]*(?:_[a-z0-9]+)*)\b/) { tokens << Regexp.last_match(1) }
    tokens.uniq.select do |t|
      (t.include?("_") || known_params.include?(t)) &&
        !NON_PARAM_TOKENS.include?(t) && !verb_names.include?(t)
    end
  end

  # Further verb names chained onto the target with "/" or "," —
  # "pass it to edit_listing / close_listing as `listing_id`" routes to BOTH.
  # Takes the text following the first target, returns [names, remaining text].
  def self.chained_targets(rest, names)
    found = []
    loop do
      m = rest.match(/\A\s*[\/,]\s*`?/)
      break unless m

      after = rest[m.end(0)..].to_s
      hit   = names.find { |n| after.start_with?(n) }
      break unless hit

      found << hit
      rest = after[hit.length..].to_s
      rest = rest[1..].to_s if rest.start_with?("`")
    end
    [found, rest]
  end

  # Every cross-reference in `verb`'s description, as
  # {target:, tokens:, phrase:}.
  #
  # Scanned one verb name at a time with literal matches (never one big
  # alternation over a lazy span — that backtracks catastrophically on the
  # long descriptions these files carry).
  def self.cross_references(verb, by_name, known_params)
    names = by_name.keys
    desc  = verb[:description]
    found = []

    names.each do |target|
      lit = Regexp.escape(target)

      # ── Form A: "<trigger> <span> to <verb>[ / <verb>]… [as <tail>]" ──
      pos = 0
      while (m = desc.match(/\bto\s+`?#{lit}`?/, pos))
        pos = m.end(0)
        # The span is what stands between the last trigger word and "to <verb>",
        # within the same sentence.
        sentence = desc[0...m.begin(0)][/[^.;]*\z/].to_s
        trigger  = sentence.rindex(TRIGGER)
        next if trigger.nil?

        span = sentence[trigger..]
        chained, after = chained_targets(desc[pos..].to_s, names)
        # "… as `booking_id`" — the naming half of the clause. Bounded by the
        # sentence end AND by a closing paren, so a parenthetical aside
        # ("(pass it to edit_listing as `listing_id`), title, body, …") does not
        # swallow the row-field list that follows it.
        tail   = after[/\A\s*(?:\([^)]*\)\s*)?as\s+([^.;)]{0,160})/, 1].to_s
        tokens = param_like("#{span} #{tail}", known_params, names)
        next if tokens.empty?

        phrase = "…#{span.strip} to #{([target] + chained).join(" / ")}" \
                 "#{tail.empty? ? "" : " as #{tail.strip}"}"
        ([target] + chained).uniq.each { |t| found << { target: t, tokens: tokens, phrase: phrase } }
      end

      # ── Form B: a literal call signature, "reschedule_delivery(order_id, …)" ──
      desc.scan(/\b#{lit}\(([^)]*)\)/) do
        args   = Regexp.last_match(1)
        tokens = param_like(args, known_params, names)
        next if tokens.empty?

        found << { target: target, tokens: tokens, phrase: "#{target}(#{args})" }
      end
    end

    found
  end

  monorepo_root = File.expand_path("../..", __dir__) # spec/ -> kiosk-test-support/ -> reference/
  # …/kiosk-demo-X/config/initializers/kiosk.rb → …/kiosk-demo-X
  demo_dirs = Dir[File.join(monorepo_root, "kiosk-demo-*/config/initializers/kiosk.rb")]
              .sort.map { |path| File.expand_path("../../..", path) }

  it "finds the demo descriptor sources" do
    expect(demo_dirs).not_to be_empty
  end

  # Non-vacuity guard. The lint is a text matcher; if the descriptors MOVE to a
  # file it does not read, every per-demo example goes green while checking
  # NOTHING. That is not hypothetical: T-057 walked the verbs out of the
  # initializers into handler controllers one demo at a time, and while this
  # lint read only initializers each migrated demo silently dropped to zero.
  #
  # K-846 restates the guard on the right property. It used to demand that each
  # demo still resolve at least one CROSS-REFERENCE, which is a demand that the
  # prose keep naming params — ADR-0023 forbids that, so writing a description
  # correctly turned this suite red. What actually has to hold is that the
  # extractor still SEES each demo's descriptors: verbs, with prose, with
  # declared inputs. A demo whose descriptions are fully ADR-0023-clean passes
  # this and resolves zero cross-references, and both are correct.
  it "actually reads every demo's descriptors (the lint is not vacuous)" do
    seen = demo_dirs.to_h do |dir|
      verbs = DescriptorSource.demo_verbs(dir)
      [File.basename(dir), {
        verbs:    verbs.size,
        described: verbs.count { |v| !v[:description].empty? },
        schemas:  verbs.count { |v| v[:params].any? },
      }]
    end

    expect(seen.values.sum { |c| c[:verbs] }).to be >= 40,
                                                 "the extractor found only #{seen.values.sum { |c| c[:verbs] }} " \
                                                 "verb(s) across the fleet #{seen.inspect} — the descriptors have " \
                                                 "moved somewhere this lint does not read"
    dark = seen.reject { |_demo, c| c[:verbs].positive? && c[:described].positive? && c[:schemas].positive? }
    expect(dark.keys).to be_empty,
                         "these demos yielded no readable descriptors: #{dark.inspect} — verbs, prose or " \
                         "input_schema moved somewhere this lint does not read"
  end

  # ── ADR-0023: a description may not carry a parameter list (K-846) ────────
  #
  # `params:` was a first-class descriptor field until ADR-0023 §Decision 4
  # retired it. Deleting the field did not delete the habit: atablefor kept
  # writing the same list one layer over, in prose — "(params: restaurant_id,
  # restaurant_table_id, date, time, party_size)" on `book_table`, "(params:
  # party_size; optional neighborhood, time, date filters)" on `availability` —
  # in the very demo the ADR was written about, duplicating an `input_schema`
  # that already declared all five. `spec/descriptor-house-style.md` §1
  # prohibits "a field or parameter list, or any param name that input_schema
  # declares"; this is the mechanical half of that, and the half that catches
  # the retired field coming back through the prose door.
  it "no demo description carries a prose parameter list (ADR-0023 §Decision 1/4)" do
    offenders = demo_dirs.flat_map do |dir|
      demo = File.basename(dir)
      DescriptorSource.demo_verbs(dir).filter_map do |verb|
        m = verb[:description].match(/(\(\s*)?\bparams?\s*:/i)
        next if m.nil?

        "#{demo} #{verb[:name]}: description writes a parameter list — " \
          "#{verb[:description][[m.begin(0) - 40, 0].max, 120].inspect}"
      end
    end

    expect(offenders).to be_empty, <<~MSG
      #{offenders.size} description(s) carry a prose parameter list:

      #{offenders.join("\n")}

      ADR-0023 re-scoped `description` to semantics only and retired the
      `params:` field; restating it in prose is the same duplication one layer
      over. Every name, type and constraint belongs in `input_schema`, and the
      row->input mapping belongs in the two schemas' per-property descriptions.
    MSG
  end

  demo_dirs.each do |dir|
    demo = File.basename(dir)

    it "#{demo}: every verb description's cross-reference names params the target verb declares" do
      verbs   = DescriptorSource.demo_verbs(dir)
      by_name = verbs.to_h { |v| [v[:name], v] }
      known   = verbs.flat_map { |v| v[:params] }.uniq

      failures = verbs.flat_map do |verb|
        self.class.cross_references(verb, by_name, known).flat_map do |ref|
          target = by_name.fetch(ref[:target])
          (ref[:tokens] - target[:params]).map do |bad|
            "#{demo} #{verb[:name]}: description routes `#{bad}` to #{target[:name]}, " \
              "which declares #{target[:params].inspect} — #{ref[:phrase].inspect}"
          end
        end
      end

      expect(failures).to be_empty, <<~MSG
        #{failures.size} unresolvable descriptor cross-reference(s):

        #{failures.join("\n")}

        A description that names a param the target verb rejects is what the
        assistant sends first (K-494). Name the target's REAL input, and state
        the row→input mapping when the row field is spelled differently.
      MSG
    end
  end
end
