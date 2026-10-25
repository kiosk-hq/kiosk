# frozen_string_literal: true

# Spec Section 8.5.5: delivery is ordered per origin. The socket-level proof is
# in events_socket_spec.rb; this one holds the live events a replay overtakes.
RSpec.describe Kiosk::Server::EventsReplay do
  let(:store) { MemoryEventStore.new }
  let(:group) { described_class.new('u1') }
  let(:sent) { [] }

  before { Kiosk.configure { |c| c.event_store = store } }

  def append(topic) = store.append('u1', { 'topic' => topic }).then { |id| { 'id' => id, 'topic' => topic } }

  def member(topic)
    group.join(0) { |event| sent << event['id'] if event['topic'] == topic }
  end

  it 'holds live events until every member is confirmed, then sends one ascending order' do
    todos = member('todo')
    lists = member('list')
    group.close
    first = append('todo')
    second = append('list')
    third = append('todo')
    todos.live(third)
    todos.confirmed
    expect(sent).to be_empty

    lists.confirmed
    later = append('list')
    lists.live(later)
    expect(sent).to eq([first, second, third, later].pluck('id'))
  end

  it 'sends a held live event the replay could not read yet, after the replay' do
    todos = member('todo')
    group.close
    replayed = append('todo')
    unread = { 'id' => replayed['id'] + 1, 'topic' => 'todo' }
    todos.live(unread)
    todos.confirmed
    expect(sent).to eq([replayed['id'], unread['id']])
  end

  it 'admits no member after it closes' do
    group.close
    expect(group.join(0) { nil }).to be_nil
  end
end
