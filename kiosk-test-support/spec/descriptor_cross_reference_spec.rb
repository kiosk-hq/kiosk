# frozen_string_literal: true

# Descriptor cross-reference lint (K-494).
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
# This lint resolves every such cross-reference against the target verb's own
# declared params, across all seven demos, so that whole class of drift fails
# the suite instead of an assistant's first call.
#
# It reads the sources as TEXT (no Rails boot, no DB), the same technique as
# skill_pin_spec.rb, and a demo declares its verbs in one of TWO places, so both
# are read and merged: the initializer's `Kiosk::Server::{Queries,Actions}
# .register(…)` calls, and — since T-053/T-057 — the class-level macros of the
# handler controllers under `app/controllers/kiosk/`. A migrating demo has some
# of each, and a cross-reference points across the query/action controller
# split, so the two lists are ONE list per demo.
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

    # Every `Kiosk::Server::{Queries,Actions}.register(…)` argument list in the
    # file, as raw source text (a string-aware balanced-paren scan, so parens
    # and quotes inside descriptions do not derail it).
    def registrations(src)
      out = []
      offset = 0
      while (m = src.match(/Kiosk::Server::(?:Queries|Actions)\.register\(/, offset))
        start = m.end(0)
        i = start
        depth = 1
        in_str = false
        while i < src.length && depth.positive?
          ch = src[i]
          if in_str
            if ch == "\\" then i += 1
            elsif ch == '"' then in_str = false
            end
          else
            case ch
            when '"' then in_str = true
            when "(" then depth += 1
            when ")" then depth -= 1
            end
          end
          i += 1
        end
        out << src[start...(i - 1)]
        offset = i
      end
      out
    end

    # The value of a `key:` whose value is one or more adjacent double-quoted
    # string literals (Ruby's `"a" \` + newline + `"b"` continuation), joined.
    def string_value(header, key)
      m = header.match(/(?<![a-z_])#{key}:\s*/)
      return nil unless m

      adjacent_strings(header, m.end(0))
    end

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

    def brace_body(text, key)
      found = brace_body_at(text, key)
      found && found.first
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

    # {name:, description:, params: [declared param names]} per registration.
    def verbs(src)
      registrations(src).filter_map do |header|
        name = header[/\A\s*"([^"]+)"/, 1]
        next if name.nil?

        schema = brace_body(header, "input_schema")
        declared = top_level_keys(brace_body(header, "params")) +
                   schema_property_names(schema)
        { name: name, description: string_value(header, "description").to_s,
          params: declared.uniq }
      end
    end

    # The same, read out of a HANDLER CONTROLLER (T-053 mixin / T-057). There
    # the descriptor is not a `register(…)` argument list but class-level macros
    # that the NEXT `def` claims:
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
        schema_props = schema_property_names(header)
        next if description.nil? && schema_props.empty?

        name = macro_string_value(header, "wire_name") || method_name
        out << { name: name, description: description.to_s, params: schema_props.uniq }
      end
      out
    end

    # Every verb a demo publishes, whichever way it declares them: the
    # initializer's surviving `register(…)` calls PLUS every handler controller
    # under app/controllers/kiosk/. Merged into ONE list per demo because a
    # cross-reference routinely points across the split — atablefor's
    # `availability` (a query controller) names `book_table` (an action
    # controller), which is exactly the K-494 drift this lint exists for.
    def demo_verbs(demo_dir)
      initializer = File.join(demo_dir, "config/initializers/kiosk.rb")
      from_init   = File.exist?(initializer) ? verbs(File.read(initializer)) : []
      from_ctrls  = Dir[File.join(demo_dir, "app/controllers/kiosk/**/*.rb")].sort
                       .flat_map { |path| controller_verbs(File.read(path)) }
      from_init + from_ctrls
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

  # Non-vacuity guard. The lint is a text matcher; if the descriptors are
  # reworded into a shape it stops recognising — or MOVED to a file it does not
  # read — every per-demo example would go green while checking NOTHING. That is
  # not hypothetical: T-057 walks the verbs out of the initializers and into
  # handler controllers one demo at a time, and while this lint read only
  # initializers, each migrated demo silently dropped to zero. philslist and
  # stylish went first and this floor absorbed them; atablefor — the very demo
  # K-494 was FOUND on — was the third, and tripped it. Assert the lint still
  # resolves a substantial body of real cross-references (17 across the seven
  # demos, the same total as before the migrations started).
  it "actually resolves cross-references (the lint is not vacuous)" do
    counts = demo_dirs.to_h do |dir|
      verbs   = DescriptorSource.demo_verbs(dir)
      by_name = verbs.to_h { |v| [v[:name], v] }
      known   = verbs.flat_map { |v| v[:params] }.uniq
      total   = verbs.sum { |v| self.class.cross_references(v, by_name, known).size }
      [File.basename(dir), total]
    end

    expect(counts.values.sum).to be >= 12,
                                "the lint resolved only #{counts.values.sum} cross-reference(s) " \
                                "#{counts.inspect} — it has stopped recognising the descriptors' " \
                                "\"pass X to <verb>\" shape and is no longer checking anything"
    # …and no demo may go dark on its own: a zero here is the migration-shaped
    # failure above, seen one demo before it can hide behind the others' total.
    expect(counts.reject { |_demo, n| n.positive? }.keys).to be_empty,
                                                            "these demos resolved ZERO cross-references: " \
                                                            "#{counts.inspect} — their descriptors moved somewhere this lint does not read"
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
