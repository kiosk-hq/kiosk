# frozen_string_literal: true

require 'action_cable'

# Top level, unsuffixed, because Action Cable constantizes the channel named
# in a subscribe frame: this class name IS the protocol's channel name.
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
  MAX_CURSOR = (2**53) - 1

  def subscribed
    return reject unless connection.kiosk_credential_holds?

    declaration = Kiosk::Server::Events.fetch(params[:topic].to_s)
    return reject unless declaration && well_formed?

    assign(declaration)
    return reject unless reachable?(declaration)

    transmit(open_delivery!)
  end

  # Action Cable confirms once the pubsub subscription is live, so replay
  # starts here: an event emitted before that reaches the client this way.
  def transmit_subscription_confirmation
    super
    @replay.confirmed
  end

  private

  def identity_key = connection.kiosk_identity_key

  def identity = connection.kiosk_identity

  def store = Kiosk.configuration.event_store

  # `head` is the cursor the client records; `truncated` says events after
  # its `since` were pruned, so it re-reads state once through the verb.
  def subscribed_frame
    {
      'type' => 'subscribed',
      'topic' => @topic,
      'subject' => @subject,
      'head' => @head,
      'truncated' => since ? store.truncated?(identity_key, since) : false
    }
  end

  # Replay and live delivery both come here, through {Kiosk::Server::EventsReplay}.
  # An event may arrive twice; delivery is at-least-once and the client
  # ignores an `id` it has seen.
  def deliver(event)
    transmit(event) if for_this_subscription?(event)
  end

  def since = params[:since]

  def assign(declaration)
    @topic = params[:topic].to_s
    @subject = params[:subject]
    @declaration = declaration
  end

  def well_formed?
    (since.nil? || cursor?(since)) && (params[:subject].nil? || params[:subject].is_a?(String))
  end

  # Reads head before the stream opens, so no event falls between head and
  # stream. Returns the `subscribed` frame, built before the replay group
  # counts this subscription.
  def open_delivery!
    @head = store.head
    subscribed_frame.tap do
      @replay = connection.kiosk_replay_member(since || @head) { |event| deliver(event) }
      open_stream!
    end
  end

  # Without `coder:` the block receives the raw broadcast String.
  def open_stream!
    stream_from Kiosk::Server::EventsCable.stream_name(identity_key, @topic),
                coder: ActiveSupport::JSON do |event|
      @replay.live(event)
    rescue StandardError => e
      logger&.error("[kiosk] events delivery failed for topic #{@topic.inspect}: #{e.class}: #{e.message}")
    end
  end

  # On the pubsub's own thread, in the order it hands events over (spec
  # Section 8.5.5). Action Cable's worker pool would reorder them.
  def worker_pool_stream_handler(broadcasting, user_handler, coder: nil)
    stream_handler(broadcasting, user_handler, coder:)
  end

  def cursor?(value) = value.is_a?(Integer) && value.between?(0, MAX_CURSOR)

  # Its own topic (the replayed tail holds every topic) and, when named, its
  # own subject (a stream name carries none).
  def for_this_subscription?(event)
    return false unless event['topic'] == @topic
    return true if @subject.nil?

    event['subject'].to_s == @subject.to_s
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
    log_rule_failure(e)
    false
  end

  # Logged, because the refusal alone cannot tell a broken rule from a no.
  def log_rule_failure(error)
    logger&.error("[kiosk] events subject rule raised for topic #{@topic.inspect}: " \
                  "#{error.class}: #{error.message} at #{error.backtrace&.first}")
  end

  # Runs every REAUTHORISE_EVERY_SECONDS. A withdrawn reach is final for this
  # subscription, so the declaration is dropped and the frame sent once.
  def reauthorise!
    return if @declaration.nil? || reachable?(@declaration)

    @declaration = nil
    # Braces required: bare pairs would be read as `transmit`'s keywords.
    transmit({ 'type' => 'unsubscribed', 'topic' => @topic, 'reason' => 'reach_revoked' })
    stop_all_streams
  rescue StandardError => e
    logger&.error("[kiosk] events re-authorisation failed: #{e.class}: #{e.message}")
  end
end
