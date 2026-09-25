#!/usr/bin/env python3
"""Kiosk event-stream listener — the pinned reference client.

Opens ONE WebSocket to an operator's `events_url`, subscribes to the topics you
name, and writes every message it receives as one JSON line on stdout. The
operator pushes when something happens, so there is nothing to poll and no
cadence to invent.

    python3 listen.py --url wss://shop.example/kiosk/events \
                      --token "$KIOSK_TOKEN" \
                      --topic order_delivery --topic order_payment:<order-id>

WAITING FOR ONE THING to happen -- a human finishing an identity check, a card
being saved? Add `--until-event` and run it IN THE FOREGROUND: it prints the
first event and exits 0 the moment it arrives, so a wait costs what the human
took and not the deadline. At the deadline with nothing it exits 5, and you
wait again. Do not background it and poll a log file -- a turn-based runtime is
never woken by a line landing in a file, and an event that arrives between
turns is an event nobody reads.

    python3 listen.py --url … --token … --topic kyc_verification \
                      --until-event --max-seconds 300

For an event that lands hours later, when you are not running, the CURSOR is
the delivery mechanism: record the highest `id` you saw and start again with
`--since <id>`.

Each line is a JSON object with a `type`:

    {"type":"open"}                        the socket is up and authenticated
    {"type":"subscribed","topic":…,"head":…,"truncated":…}
    {"type":"event","id":…,"topic":…,"subject":…,"occurred_at":…,"data":{…}}
    {"type":"rejected","topic":…}          that topic is not yours to read
    {"type":"unsubscribed","topic":…,"reason":…}   you lost reach mid-stream
    {"type":"disconnect","reason":…,"reconnect":…}
    {"type":"reconnecting","in":…,"since":…}
    {"type":"error","message":…}

EXIT CODES: 0 you asked it to stop (--max-seconds), or --until-event got its
event; 2 the arguments or the URL are wrong; 3 the operator will not have this
token back and no --token-command was given — mint a fresh one and start it
again; 4 every topic you named was refused, so this would have waited forever
for something that cannot arrive; 5 --until-event reached the deadline with
nothing.

It needs `websockets` from PyPI (>= 12, the release that added the threading
client). Add it to the same venv the skill already has you create:

    pip install 'websockets>=12'

Do NOT replace this file with a client of your own. The subprotocol token, the
string-inside-a-string `identifier`, and the resume contract are each a place a
hand-rolled client is dropped with no diagnostic, and you would read that
silence as "nothing happened".
"""

import argparse
import json
import random
import subprocess
import sys
import time
from urllib.parse import urlencode, urlsplit, urlunsplit

import websockets
from websockets.sync.client import connect

SUBPROTOCOL = "actioncable-v1-json"
# The operator's own beat is one ping every thirty seconds. Three missed in a
# row is a socket that is gone without having said so — half-open TCP, a dozing
# laptop, an edge that dropped us — and the only way to find out is to stop
# waiting.
IDLE_TIMEOUT = 95
BACKOFF_CAP = 30


def emit(**line):
    """One JSON object per line, flushed, so a tail sees it immediately."""
    sys.stdout.write(json.dumps(line, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def origin_of(url):
    """The `Origin` header an operator's CSRF check reads: scheme + host only."""
    parts = urlsplit(url)
    scheme = "https" if parts.scheme == "wss" else "http"
    return urlunsplit((scheme, parts.netloc, "", "", ""))


def stream_url(url, topics, since):
    """`?topic=` is how you subscribe: the operator reads it on connect and
    confirms each one, so a round trip per topic is not needed."""
    query = [("topic", ",".join(topics))]
    if since is not None:
        query.append(("since", str(since)))
    parts = urlsplit(url)
    return urlunsplit((parts.scheme, parts.netloc, parts.path, urlencode(query), ""))


def read_frames(socket, state, deadline):
    """Drain one connection, and say what to do next.

    "retry" reconnect · "stop" --max-seconds is up · "event" --until-event got
    its event · "credential" the operator will not have this token back ·
    "unreadable" every topic was refused.

    The read is bounded rather than blocking forever: a deadline nothing
    checks is not a deadline, and a socket that died without saying so looks
    exactly like a quiet one.
    """
    while True:
        budget = IDLE_TIMEOUT
        if deadline:
            budget = min(budget, deadline - time.monotonic())
            if budget <= 0:
                return "stop"
        try:
            raw = socket.recv(timeout=budget)
        except TimeoutError:
            # The deadline, or three of the operator's beats missed — a socket
            # that died without saying so. Neither is an error worth a line.
            return "stop" if deadline and time.monotonic() >= deadline else "retry"
        frame = json.loads(raw)
        kind = frame.get("type")

        if kind in ("ping", "welcome"):
            continue

        if kind == "confirm_subscription":
            state["confirmed"] += 1
            continue

        if kind == "reject_subscription":
            emit(type="rejected", topic=topic_of(frame))
            state["rejected"] += 1
            # EVERY topic refused and none confirmed: there is nothing on
            # this socket to wait for, ever. Say so rather than sit on it.
            if state["confirmed"] == 0 and state["rejected"] >= state["wanted"]:
                return "unreadable"
            continue

        if kind == "disconnect":
            emit(type="disconnect", reason=frame.get("reason"),
                 reconnect=frame.get("reconnect", True))
            # `reconnect: false` is the operator saying this credential is done:
            # it expired, or the human revoked the assistant. A retry with the
            # same bearer loses the same argument, so mint a new one or stop.
            if frame.get("reconnect", True):
                return "retry"
            return "retry" if state["refresh"] else "credential"

        message = frame.get("message")
        if not isinstance(message, dict):
            continue

        if message.get("type") == "subscribed":
            # `head` is where the operator's tail stood when this subscription
            # opened. Adopt it as the resume floor NOW rather than waiting for
            # a first event: a socket that drops before anything arrives would
            # otherwise reconnect asking for nothing in particular, and every
            # event emitted during the gap would be missed in silence.
            if message.get("head") is not None:
                state["since"] = max(state["since"] or 0, int(message["head"]))
            emit(**message)
            continue

        if message.get("type") == "unsubscribed":
            emit(**message)
            continue

        # An event. Its `id` is per-operator and monotonic, so the highest one
        # seen is exactly what `since` wants after a drop.
        if message.get("id") is not None:
            state["since"] = max(state["since"] or 0, int(message["id"]))
        emit(type="event", **message)
        # The one-shot wait is over the moment the thing you waited for lands.
        # A `subscribed` confirmation is not that, and neither is a beat.
        if state["one_shot"]:
            return "event"


def topic_of(frame):
    try:
        return json.loads(frame.get("identifier") or "{}").get("topic")
    except ValueError:
        return None


def main():
    parser = argparse.ArgumentParser(description="Kiosk event-stream listener")
    parser.add_argument("--url", required=True, help="the operator's events_url")
    parser.add_argument("--token", required=True, help="your bearer token")
    parser.add_argument("--topic", action="append", required=True, metavar="NAME[:SUBJECT]",
                        help="repeatable; NAME:SUBJECT narrows to one row")
    parser.add_argument("--since", type=int, help="resume after this event id")
    parser.add_argument("--origin", help="override the Origin header")
    parser.add_argument("--token-command",
                        help="shell command printing a fresh bearer token; run when the "
                             "operator says this one will not be accepted back")
    parser.add_argument("--max-seconds", type=float, help="stop after this long")
    parser.add_argument("--until-event", action="store_true",
                        help="exit 0 on the first event, 5 at --max-seconds with none; "
                             "run in the foreground to wait for one thing to happen")
    args = parser.parse_args()

    if urlsplit(args.url).scheme not in ("ws", "wss"):
        parser.error("--url must be ws:// or wss://")
    if args.until_event and not args.max_seconds:
        parser.error("--until-event needs --max-seconds: a foreground wait with no deadline "
                     "is a tool call that never returns")

    state = {"since": args.since, "token": args.token, "refresh": args.token_command,
             "wanted": len(args.topic), "confirmed": 0, "rejected": 0,
             "one_shot": args.until_event}
    deadline = time.monotonic() + args.max_seconds if args.max_seconds else None
    attempt = 0

    while True:
        if deadline and time.monotonic() >= deadline:
            return 5 if args.until_event else 0
        try:
            with connect(stream_url(args.url, args.topic, state["since"]),
                         subprotocols=[SUBPROTOCOL],
                         additional_headers={
                             "Authorization": f"Bearer {state['token']}",
                             "Origin": args.origin or origin_of(args.url)},
                         open_timeout=15, close_timeout=5) as socket:
                emit(type="open")
                attempt = 0
                state["confirmed"] = state["rejected"] = 0
                verdict = read_frames(socket, state, deadline)
                if verdict == "event":
                    return 0
                if verdict == "stop":
                    return 5 if args.until_event else 0
                if verdict == "unreadable":
                    return 4
                if verdict == "credential":
                    return 3
        except KeyboardInterrupt:
            return 0
        except websockets.InvalidStatus as error:
            # The upgrade itself was refused, which on this wire means the
            # bearer did not resolve. Nothing about waiting changes that.
            emit(type="error", message=f"upgrade refused: {error.response.status_code}")
            if state["refresh"] is None:
                return 3
        except Exception as error:  # noqa: BLE001 — every transport fault is one retry
            emit(type="error", message=f"{type(error).__name__}: {error}")

        if state["refresh"] is not None:
            fresh = subprocess.run(state["refresh"], shell=True, capture_output=True,
                                   text=True, check=False)
            if fresh.returncode == 0 and fresh.stdout.strip():
                state["token"] = fresh.stdout.strip()
            else:
                emit(type="error", message="--token-command produced no token")
                return 3

        attempt += 1
        wait = min(2 ** (attempt - 1), BACKOFF_CAP) * (0.5 + random.random())
        if deadline:
            wait = min(wait, max(0.0, deadline - time.monotonic()))
        emit(type="reconnecting", **{"in": round(wait, 2), "since": state["since"]})
        time.sleep(wait)


if __name__ == "__main__":
    sys.exit(main())
