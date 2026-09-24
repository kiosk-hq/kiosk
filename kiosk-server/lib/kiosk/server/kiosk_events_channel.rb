# frozen_string_literal: true

require "action_cable"

# THE ONE TOP-LEVEL CONSTANT THIS GEM DEFINES, and it is not a style slip.
#
# Action Cable resolves the channel a client asks for by constantizing the
# string in the subscribe frame's `identifier`
# (`Connection::Subscriptions#add`: `id_options[:channel].safe_constantize`).
# So the name on the WIRE and the name of a Ruby class are the same string.
# `Kiosk::Server::KioskEventsChannel` would therefore put a Ruby module path
# into the protocol, which every porter would then have to reproduce to speak
# it — a Rails implementation detail promoted to a wire constant.
#
# `KioskEvents` is the wire's name for the channel, and this class exists at
# top level so that name resolves. It is deliberately NOT suffixed `Channel`:
# the suffix is a Rails naming convention, and this identifier is published.
#
#   {"command":"subscribe",
#    "identifier":"{\"channel\":\"KioskEvents\",\"topic\":\"todo\",\"subject\":\"list_4f1e…\"}"}
#
class KioskEvents < ActionCable::Channel::Base
  # Spec Section 8.5.6 requires re-authorisation at least every 60 seconds, and
  # this is why. The revocation watermark is checked inside `JwtIssuer.verify`, i.e.
  # once per token verification, i.e. once per HTTP request — so a socket
  # verified only at connect would never observe a later `revoke_all`, and an
  # unlinked assistant would keep receiving its human's data for the rest of
  # the token's hour. Re-verifying on a timer bounds that to this many seconds.
  REAUTHORISE_EVERY_SECONDS = 30

  periodically :reauthorise!, every: REAUTHORISE_EVERY_SECONDS

  def subscribed
    topic = params[:topic].to_s
    declaration = Kiosk::Server::Events.fetch(topic)

    # A topic this origin does not declare is refused rather than streamed
    # empty: a silent subscription to nothing is indistinguishable from a quiet
    # topic, and the client would wait forever on a name it got wrong.
    return reject unless declaration

    # ORDER MATTERS AND IT BIT ONCE: `reachable?` reads `@subject`, so the
    # assignment has to precede it. With it after, every `consented`
    # subscription authorised against a nil subject and was refused — including
    # the ones that should have been allowed, which reads from the outside like
    # a working deny rule.
    @topic = topic
    @subject = params[:subject]
    @declaration = declaration

    return reject unless reachable?(declaration)

    # HEAD IS READ BEFORE THE STREAM IS OPENED, and that ordering is the whole
    # of the race fix below. Read it after and there is a window in which an
    # event is newer than the head we published and older than the stream we
    # opened — belonging to neither, and therefore lost.
    @head = store.head

    # `coder:` is REQUIRED with a block. Without it the handler is handed the
    # raw broadcast STRING rather than the decoded event, so every filter below
    # reads a String as a Hash — `event["subject"]` becomes a substring search —
    # and the client receives a JSON document nested inside a JSON frame.
    stream_from Kiosk::Server::EventsCable.stream_name(identity_key, topic),
                coder: ActiveSupport::JSON do |event|
      transmit(event) if for_this_subscription?(event)
    end

    transmit(subscribed_frame)
  end

  # THE POINT AT WHICH THE STREAM IS ACTUALLY LIVE, and therefore the only
  # correct place to replay from.
  #
  # `stream_from` POSTS the pubsub subscribe to Action Cable's event loop and
  # defers this confirmation until it succeeds — so between the end of
  # `subscribed` and this call there is a window in which the client holds our
  # `subscribed` frame and no stream. MEASURED 2026-09-25: an event emitted in
  # that window reached nobody at all. Replaying HERE closes it, because
  # everything after the head we captured before opening the stream is sent
  # once the stream exists.
  def transmit_subscription_confirmation
    super
    replay!
  end

  def unsubscribed
    stop_all_streams
  end

  private

  def identity_key = connection.kiosk_identity_key

  def identity = connection.kiosk_identity

  def store = Kiosk.configuration.event_store

  # `head` is the operator's current event id — what the client records as its
  # cursor. `truncated` is the whole of the degraded case: "I cannot prove you
  # saw everything", answered by ONE ordinary tolled read of the verb that owns
  # this state, after which the client continues on the stream.
  def subscribed_frame
    {
      "type" => "subscribed",
      "topic" => @topic,
      "subject" => @subject,
      "head" => @head,
      "truncated" => since ? store.truncated?(identity_key, since) : false,
    }
  end

  # REPLAY ALWAYS RUNS, and not only when the caller sent a `since`. The floor
  # is `since` when the caller gave one and the head captured before the stream
  # was opened when it did not: either way, everything after the cursor the
  # client is about to hold.
  #
  # An event may therefore arrive twice — once from here and once from the
  # stream. That costs nothing and is not a defect: delivery is at-least-once
  # by construction, and the wire already requires a client to ignore an `id`
  # it has seen. Losing one, which is what the conditional replay did, has no
  # such remedy.
  def replay!
    return if @head.nil?

    floor = since || @head

    store.since(identity_key, floor).each do |event|
      transmit(event) if for_this_subscription?(event)
    end
  end

  def since
    value = params[:since]
    return nil if value.nil? || value.to_s.empty?

    value.to_i
  end

  # A subject-scoped subscription sees only its subject. The stream is per
  # (identity, topic), so this is where the narrowing happens — see
  # {Kiosk::Server::EventsCable} for why a subject is not in the stream name.
  def for_this_subscription?(event)
    return true if @subject.nil?

    event["subject"].to_s == @subject.to_s
  end

  # Spec Section 8.5.6. `reach` authorises the SUBSCRIPTION, exactly as it
  # authorises a call
  # to the verb beside it; `subject_reachable` answers the operator's own
  # question about THIS subject, and takes the subject and the identity rather
  # than reading CurrentRequest — which is fiber-local and does not reach here.
  def reachable?(declaration)
    case declaration[:reach]
    when :published then true
    when :principal then @subject.nil? || subject_reachable?(declaration)
    else subject_reachable?(declaration)
    end
  end

  def subject_reachable?(declaration)
    callable = declaration[:subject_reachable]
    # A topic that declares no predicate authorises by `reach` alone. For
    # `principal` that is the whole answer; for `consented` and `role` it is an
    # operator who has not yet said who may read it, and the safe reading of
    # silence on an authorisation question is NO.
    return declaration[:reach] == :principal if callable.nil?

    !!callable.call(@subject, identity)
  rescue StandardError
    false
  end

  # Runs every REAUTHORISE_EVERY_SECONDS. Two different failures, two different
  # answers, and the difference matters to a client deciding whether to come
  # back: a reach that was withdrawn is about THIS subscription, while a
  # revoked token is about the whole connection and will not change by
  # reconnecting — a client that retries into it is a reconnect storm against
  # an origin whose answer is fixed.
  def reauthorise!
    return if @declaration.nil?

    unless Kiosk::Server::IdentityResolution.resolve(connection.request)
      connection.transmit(
        "type" => "disconnect", "reason" => "revoked", "reconnect" => false
      )
      connection.close
      return
    end

    return if reachable?(@declaration)

    transmit("type" => "unsubscribed", "topic" => @topic, "reason" => "reach_revoked")
    stop_all_streams
  end
end
