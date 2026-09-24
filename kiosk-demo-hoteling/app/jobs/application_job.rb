# frozen_string_literal: true

# The base class every job in this demo inherits, which is Rails' own
# convention and the file an adopter expects to find.
#
# The adapter is `:async` (config/application.rb): in-process, no tables, no
# worker. The trade is stated where it is made — an enqueued job is lost if the
# process stops before it runs — and it is acceptable HERE because scheduling
# the hotel's own decision is this demo's domain work, not a step of the Kiosk
# wire. Nothing an operator copies from it is a claim about the protocol.
class ApplicationJob < ActiveJob::Base
end
