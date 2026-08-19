# frozen_string_literal: true

# Every published verb declares a `description`, an `input_schema` AND an
# `output_schema` (T-073 = A, Phil 2026-08-17: both schemas REQUIRED on every
# verb in 0.4).
#
# WHY A TEXT LINT WHEN THE ENGINE ALREADY RAISES. {HandlerMixin} refuses a
# declaration missing either schema at class-body load, which is the real
# enforcement — an origin with an incomplete descriptor does not boot. This is
# the FLOOR under it: it reads the eight origins' sources directly, needs no
# database and no Rails, runs in a second in the gems matrix, and names the
# offending verb rather than failing somewhere inside a demo's `rake demo:setup`
# fifteen minutes into the demos matrix. It also covers the case the engine
# cannot see: a verb whose declaration is present but EMPTY, and an origin
# nobody remembered to name in `c.handlers` (the class never loads, so the
# mixin never runs) — the K-761 hole.
#
# The extraction is descriptor_cross_reference_spec.rb's, for the same reason it
# is that spec's: a demo declares its verbs in ONE place, the class-level macro
# run above each `def` in `app/controllers/kiosk/*.rb`.
RSpec.describe "descriptor required fields" do
  REQUIRED_MACROS = %w[description input_schema output_schema].freeze

  # The macro run above each `def`, per handler controller. A `def` with no run
  # above it is not a verb — the mixin's own rule, which is what keeps a
  # controller's private helpers out of the catalog.
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

      declared = REQUIRED_MACROS.select { |macro| header.match?(/^[ \t]*#{macro}[ \t]/) }
      next if declared.empty? && !header.match?(/^[ \t]*wire_name[ \t]/)

      name = header[/^[ \t]*wire_name[ \t]+"([^"]*)"/, 1] || method_name
      out << { name: name, declared: declared }
    end
    out
  end

  monorepo_root = File.expand_path("../..", __dir__) # spec/ -> kiosk-test-support/ -> reference/
  origins = Dir[File.join(monorepo_root, "kiosk-demo-*/app/controllers/kiosk/*.rb")]
            .group_by { |path| path[%r{/(kiosk-demo-[^/]+)/}, 1] }
  origins["e2e"] = Dir[File.join(monorepo_root, "e2e/fixtures/*_controller.rb")]

  it "finds the handler controllers" do
    expect(origins.keys.sort).to include("e2e", "kiosk-demo-atablefor", "kiosk-demo-tudu")
  end

  # Non-vacuity floor: the lint is a text matcher, so a reworded or relocated
  # descriptor would make every example below pass while checking nothing. 52 is
  # the fleet's verb count at the time this shipped; the assertion is `>=` so
  # adding a verb never fails it, but losing sight of the fleet does.
  it "sees the whole fleet (the lint is not vacuous)" do
    total = origins.sum { |_origin, paths|
      paths.sum { |path| self.class.verbs_in(File.read(path)).length }
    }
    expect(total).to be >= 52,
                     "the lint resolved only #{total} verbs across #{origins.size} origins — " \
                     "the descriptors moved somewhere it does not read"
  end

  origins.sort.each do |origin, paths|
    it "#{origin}: every verb declares #{REQUIRED_MACROS.join(", ")}" do
      missing = paths.sort.flat_map { |path|
        self.class.verbs_in(File.read(path)).filter_map { |verb|
          absent = REQUIRED_MACROS - verb[:declared]
          next if absent.empty?

          "#{origin} #{verb[:name]} (#{File.basename(path)}): missing #{absent.join(", ")}"
        }
      }

      expect(missing).to be_empty, <<~MSG
        #{missing.size} verb(s) publish an incomplete descriptor:

        #{missing.join("\n")}

        T-073 = A makes BOTH schemas REQUIRED on every 0.4 verb: `input_schema` is
        the contract the wire coerces and validates arguments against, and
        `output_schema` is the only machine-readable statement of what a call
        returns now that the response envelope is gone. A verb that takes nothing
        still declares the closed empty object.
      MSG
    end
  end
end
