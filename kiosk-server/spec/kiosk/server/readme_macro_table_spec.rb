# frozen_string_literal: true

# THE README's «What the macros do» TABLE IS THE DECLARABLE-KEY SET, DERIVED
# (K-1582).
#
# The table under that heading is where an operator reads which macros may sit
# above a `def` — it is the page that teaches the DSL, and a key it invents is a
# line somebody writes that nothing reads, while a key it omits is a capability
# nobody finds. It was HAND-KEPT and owned by nobody: no `bin/check-*` reads it,
# and the mixin's own suite is indifferent to what the README says.
#
# THE ORACLE IS NOT A VALUE OBJECT, which is why this is a second example beside
# `readme_event_table_spec.rb` rather than another `expect` inside it. The event
# table derives from `ActionEvent.members`; there is no struct here. What a verb
# may declare is defined by the MACROS, and a macro is exactly a public method of
# {Kiosk::Server::HandlerMixin::ClassMethods} that writes into `kiosk_pending` —
# so the set is read off those assignments in the mixin's own source, and each
# key is then required to BE a public macro of that name. Reading the source is a
# lexical derivation and the second assertion is what keeps it honest: a key that
# is not a callable macro fails here rather than quietly widening the table.
#
# `Actions::Entry`'s members are deliberately NOT the oracle. MEASURED: Entry has
# seven members and the declarable set has eight; they share six. `handler` is an
# Entry member and is not declarable, `kind` and `wire_name` are declarable and
# are not Entry members. Six of eight agreeing is exactly what makes the two look
# interchangeable, and a table built off Entry would be wrong in three places.
RSpec.describe "the kiosk-server README's verb-declaration table" do
  MIXIN_SOURCE = File.expand_path("../../../lib/kiosk/server/handler_mixin.rb", __dir__)
  README_PATH  = File.expand_path("../../../README.md", __dir__)

  # Every key a macro writes. `@kiosk_pending` (the ivar the binding hook reads
  # and clears) is a different token and is not matched.
  def self.declarable_keys(source)
    source.scan(/^\s+kiosk_pending\[:([a-z_]+)\]\s*=/).flatten.uniq
  end

  # The first column of every row under the heading, as the names it carries.
  def self.table_macros(readme)
    section = readme[/^### What the macros do\n(.*?)(?=\n^### |\z)/m, 1]
    return nil if section.nil?

    section.lines
           .filter_map { |l| l[/\A\|([^|]*)\|/, 1] }
           .flat_map { |cell| cell.scan(/`([a-z_]+)`/).flatten }
           .uniq
  end

  it "lists every macro key the mixin accepts, and nothing that is not one" do
    keys = self.class.declarable_keys(File.read(MIXIN_SOURCE))
    expect(keys).not_to be_empty,
                        "no `kiosk_pending[:key] =` assignment was found in handler_mixin.rb. " \
                        "The derivation reads the macros' own writes; if they moved or changed " \
                        "shape, move this example with them — an empty oracle compares nothing " \
                        "and passes."

    listed = self.class.table_macros(File.read(README_PATH))
    expect(listed).not_to be_nil,
                          "kiosk-server/README.md has no `### What the macros do` section. That " \
                          "table is where an operator reads which macros may sit above a `def`; " \
                          "if the heading moved, move this example with it."
    expect(listed).not_to be_empty,
                          "the `What the macros do` table lists no macro at all — a table with " \
                          "no backticked names holds nothing, however green this reads."

    expect(listed.sort).to eq(keys.sort),
                           "the README's macro table and the mixin's declarable keys disagree. " \
                           "Missing from the table: #{(keys - listed).sort.inspect}. " \
                           "In the table and not declarable: #{(listed - keys).sort.inspect}. " \
                           "An operator writes their verb from this table, so a key it omits is " \
                           "a capability nobody finds — and a name it invents is a line the " \
                           "mixin will never read."
  end

  it "derives from macros and not from bare keys — every key is a public macro of that name" do
    keys    = self.class.declarable_keys(File.read(MIXIN_SOURCE))
    methods = Kiosk::Server::HandlerMixin::ClassMethods
    absent  = keys.reject { |k| methods.public_method_defined?(k) }

    expect(absent).to be_empty,
                      "these keys are written into `kiosk_pending` by something that is not a " \
                      "public macro of the same name: #{absent.sort.inspect}. The table above " \
                      "teaches macros, so a key with no macro behind it does not belong in it — " \
                      "and this example's derivation would be reading the wrong set."
  end
end
