# frozen_string_literal: true

# The base class every job in this demo inherits, which is Rails' own
# convention and the file an adopter expects to find.
#
# The adapter is `:async` (config/application.rb): in-process, no tables, no
# worker. The trade is stated where it is made — an enqueued job is lost if the
# process stops before it runs — and it is acceptable here because what these
# demos schedule is their OWN domain work: a hotel desk answering, a courier
# leaving. None of it is a step of the Kiosk wire, so nothing an operator
# copies from this file is a claim about the protocol.
class ApplicationJob < ActiveJob::Base
end
