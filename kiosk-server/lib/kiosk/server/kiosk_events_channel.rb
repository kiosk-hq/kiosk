# frozen_string_literal: true

require "action_cable"

# Top level, unsuffixed, because Action Cable constantizes the channel named
# in a subscribe frame: this class name IS the wire's channel name.
#
#   {"command":"subscribe",
#    "identifier":"{\"channel\":\"KioskEvents\",\"topic\":\"todo\",\"subject\":\"list_4f1e…\"}"}
#
class KioskEvents < ActionCable::Channel::Base
  # The subject's reach is re-checked while the subscription stands (spec
  # Section 8.5.6); the credential is the connection's to re-check.
  REAUTHORISE_EVERY_SECONDS = 30

  periodically :reauthorise!, every: REAUTHORISE_EVERY_SECONDS

  # A cursor is a non-negative integer JSON carries exactly (spec Section
  # 8.5.4, RFC 7493 Section 2.2).
  MAX_CURSOR = 2**53 - 1

  def subscribed
    return reject unless connection.kiosk_credential_holds?

    topic = params[:topic].to_s
    declaration = Kiosk::Server::Events.fetch(topic)

    return reject unless declaration
    return reject unless since.nil? || cursor?(since)
    return reject unless params[:subject].nil? || params[:subject].is_a?(String)

    @topic = topic
    @subject = params[:subject]
    @declaration = declaration

    return reject unless reachable?(declaration)

    # Before the stream opens, so no event falls between head and stream.
    @head = store.head

    # Without `coder:` the block receives the raw broadcast String.
    stream_from Kiosk::Server::EventsCable.stream_name(identity_key, topic),
                coder: ActiveSupport::JSON do |event|
      transmit(event) if for_this_subscription?(event)
    end

    transmit(subscribed_frame)
  end

  # Action Cable confirms once the pubsub subscription is live, so replay
  # starts here: an event emitted before that reaches the client this way.
  def transmit_subscription_confirmation
    super
    replay!
  end

  private

  def identity_key = connection.kiosk_identity_key

  def identity = connection.kiosk_identity

  def store = Kiosk.configuration.event_store

  # `head` is the cursor the client records; `truncated` says events after
  # its `since` were pruned, so it re-reads state once through the verb.
  def subscribed_frame
    {
      "type" => "subscribed",
      "topic" => @topic,
      "subject" => @subject,
      "head" => @head,
      "truncated" => since ? store.truncated?(identity_key, since) : false,
    }
  end

  # Everything after `since`, or after the head read before the stream
  # opened. An event may arrive twice; delivery is at-least-once and the
  # client ignores an `id` it has seen.
  def replay!
    store.since(identity_key, since || @head).each do |event|
      transmit(event) if for_this_subscription?(event)
    end
  end

  def since = params[:since]

  def cursor?(value) = value.is_a?(Integer) && value.between?(0, MAX_CURSOR)

  # Its own topic (the replayed tail holds every topic) and, when named, its
  # own subject (a stream name carries none).
  def for_this_subscription?(event)
    return false unless event["topic"] == @topic
    return true if @subject.nil?

    event["subject"].to_s == @subject.to_s
  end

  # Spec Sections 8.5.4 and 8.5.6. No subject, or a `published` topic, is
  # reachable; otherwise the topic's `subject_reachable` rule answers, and a
  # topic without one admits a named subject only under `principal` reach.
  def reachable?(declaration)
    return true if @subject.nil? || declaration[:reach] == :published

    callable = declaration[:subject_reachable]
    return declaration[:reach] == :principal if callable.nil?

    !!callable.call(@subject, identity)
  rescue StandardError => e
    # Logged, because the refusal alone cannot tell a broken rule from a no.
    logger&.error("[kiosk] events subject rule raised for topic #{@topic.inspect}: " \
                  "#{e.class}: #{e.message} at #{e.backtrace&.first}")
    false
  end

  # Runs every REAUTHORISE_EVERY_SECONDS. A withdrawn reach is final for this
  # subscription, so the declaration is dropped and the frame sent once.
  def reauthorise!
    return if @declaration.nil? || reachable?(@declaration)

    @declaration = nil
    # Braces required: bare pairs would be read as `transmit`'s keywords.
    transmit({ "type" => "unsubscribed", "topic" => @topic, "reason" => "reach_revoked" })
    stop_all_streams
  rescue StandardError => e
    logger&.error("[kiosk] events re-authorisation failed: #{e.class}: #{e.message}")
  end
end
