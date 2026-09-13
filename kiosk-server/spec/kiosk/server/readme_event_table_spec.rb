# frozen_string_literal: true

# THE README's «What the event carries» TABLE IS THE FIELD LIST, DERIVED
# (K-1579).
#
# `c.audit_sink` hands the operator one {Kiosk::Server::ActionEvent} per action
# invocation, and this gem's README is where an operator reads what is in it —
# the table under «What the event carries» is what somebody columns their own
# audit row from. It was HAND-KEPT, and it sat two of the twelve members short
# for seven days at head: `cause_class` and `cause_message` had joined the value
# object and nothing anywhere compared the two lists, so the first action that
# failed with a WRAPPED exception raised on the operator's insert.
#
# The code side was never the gap. `audit_sink_spec.rb` asserts the full
# twelve-key `event.to_h`, so adding a member reddens that file immediately —
# and says nothing at all about the README, which is exactly how the two fields
# went unlisted while the suite stayed green. K-1563 repaired the table by hand
# and installed no mechanism, so this is the mechanism: the SET is derived from
# `ActionEvent.members` and the PROSE stays the author's, which is the same
# split every derived-inventory guard in this repository makes.
#
# WHY IT IS AN EXAMPLE HERE RATHER THAN A `bin/check-*` GUARD. It sits beside
# the source of truth, it runs in the gems matrix that already runs on every
# push, and the precedent is one gem over: `kiosk-pow-equihash` holds its
# README's solve/verify lever the same way. A guard would need a CI job of its
# own to be a gate at all.
RSpec.describe "the kiosk-server README's event-field table" do
  readme = File.read(File.expand_path("../../../README.md", __dir__))

  # The first column of every row under the heading, as the names it carries.
  # A cell may pair two fields (`user_id` / `agent_id`), which is prose the
  # author owns; the NAMES are what this compares. A first cell can never carry
  # a pipe, so taking it up to the next one is safe even though a later cell in
  # the same row escapes one.
  def self.table_fields(readme)
    section = readme[/^### What the event carries\n(.*?)(?=\n^### |\z)/m, 1]
    return nil if section.nil?

    section.lines
           .filter_map { |l| l[/\A\|([^|]*)\|/, 1] }
           .flat_map { |cell| cell.scan(/`([a-z_]+)`/).flatten }
           .uniq
  end

  it "names every member of ActionEvent, and nothing that is not one" do
    listed = self.class.table_fields(readme)
    expect(listed).not_to be_nil,
                          "kiosk-server/README.md has no `### What the event carries` section. " \
                          "That table is where an operator reads what `c.audit_sink` receives; " \
                          "if the heading moved, move this example with it."

    members = Kiosk::Server::ActionEvent.members.map(&:to_s)
    expect(listed).not_to be_empty,
                          "the `What the event carries` table lists no field at all — a table " \
                          "with no backticked names holds nothing, however green this reads."

    expect(listed.sort).to eq(members.sort),
                           "the README's event table and ActionEvent disagree. " \
                           "Missing from the table: #{(members - listed).sort.inspect}. " \
                           "In the table and not in the event: #{(listed - members).sort.inspect}. " \
                           "An operator columns their audit row from this table, so a member it " \
                           "omits is a column their insert does not have — and a name it invents " \
                           "is a column nothing will ever fill."
  end
end
