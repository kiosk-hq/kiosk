# frozen_string_literal: true
zone = ReaderClock.zone
json.array! @todos do |todo|
  json.todo_id todo.id
  json.extract! todo, :title, :done, :created_by_agent_id
  json.due_at ReaderClock.publish(todo.due_at, zone)
  json.due_label ReaderClock.label(todo.due_at, zone)
  json.timezone zone.name
end
