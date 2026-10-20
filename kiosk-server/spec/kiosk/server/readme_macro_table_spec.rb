# frozen_string_literal: true

# Reads the declarable macro keys out of the mixin, and the macro table out of
# the README.
module ReadmeMacroTableSpecHelpers
  MIXIN_SOURCE = File.expand_path('../../../lib/kiosk/server/handler_mixin.rb', __dir__)
  README_PATH  = File.expand_path('../../../README.md', __dir__)

  # Every key a macro writes. `@kiosk_pending` (the ivar the binding hook reads
  # and clears) is a different token and is not matched.
  def self.declarable_keys(source = File.read(MIXIN_SOURCE))
    source.scan(/^\s+kiosk_pending\[:([a-z_]+)\]\s*=/).flatten.uniq
  end

  # The first column of every row under the heading, as the names it carries.
  def self.table_macros(readme = File.read(README_PATH))
    section = readme[/^### What the macros do\n(.*?)(?=\n^### |\z)/m, 1]
    return nil if section.nil?

    section.lines
           .filter_map { |l| l[/\A\|([^|]*)\|/, 1] }
           .flat_map { |cell| cell.scan(/`([a-z_]+)`/).flatten }
           .uniq
  end
end

RSpec.describe "the kiosk-server README's verb-declaration table" do
  it 'lists every macro key the mixin accepts, and nothing that is not one' do
    keys = ReadmeMacroTableSpecHelpers.declarable_keys
    expect(keys).not_to be_empty,
                        'no `kiosk_pending[:key] =` assignment was found in handler_mixin.rb. ' \
                        "The derivation reads the macros' own writes; if they moved or changed " \
                        'shape, move this example with them — an empty oracle compares nothing ' \
                        'and passes.'

    listed = ReadmeMacroTableSpecHelpers.table_macros
    expect(listed).not_to be_nil,
                          'kiosk-server/README.md has no `### What the macros do` section. That ' \
                          'table is where an operator reads which macros may sit above a `def`; ' \
                          'if the heading moved, move this example with it.'
    expect(listed).not_to be_empty,
                          'the `What the macros do` table lists no macro at all — a table with ' \
                          'no backticked names holds nothing, however green this reads.'

    expect(listed.sort).to eq(keys.sort),
                           "the README's macro table and the mixin's declarable keys disagree. " \
                           "Missing from the table: #{(keys - listed).sort.inspect}. " \
                           "In the table and not declarable: #{(listed - keys).sort.inspect}. " \
                           'An operator writes their verb from this table, so a key it omits is ' \
                           'a capability nobody finds — and a name it invents is a line the ' \
                           'mixin will never read.'
  end

  describe 'its derivation' do
    it 'derives from macros and not from bare keys — every key is a public macro of that name' do
      keys    = ReadmeMacroTableSpecHelpers.declarable_keys
      methods = Kiosk::Server::HandlerMixin::ClassMethods
      absent  = keys.reject { |k| methods.public_method_defined?(k) }

      expect(absent).to be_empty,
                        'these keys are written into `kiosk_pending` by something that is not a ' \
                        "public macro of the same name: #{absent.sort.inspect}. The table above " \
                        'teaches macros, so a key with no macro behind it does not belong in it — ' \
                        "and this example's derivation would be reading the wrong set."
    end
  end
end
