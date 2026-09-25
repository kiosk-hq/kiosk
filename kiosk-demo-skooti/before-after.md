# Before and after — scooter rental

**What this file is for.** An operator weighing adoption: what an AI assistant
cannot do at a micromobility operator today, and what the same errand looks
like once this demo's wire is installed. The code is in this directory; this is
the argument, not a listing.

skooti is a fake-but-realistic scooter operator built to show two things: an
accountable registration that lets an operator serve sanctioned assistants
without opening its bot-wall, and a physical last-mile a lock verifies by
itself. Nothing here implies any real operator works this way, and whether they
adopt it is an open question.

## Today

An AI assistant can find a scooter on a map. It cannot ride one. The unlock
happens inside the operator's app, authenticated to the human's account, after
a scan of that specific scooter; there is no sanctioned API that releases a
lock. Registration, the stored card and the PSD2 challenge all live with the
human. And operators fight real fraud — stolen rides, vandalism, multi-account
promo abuse — with exactly the device fingerprinting that assistant traffic
trips.

So the assistant's contribution ends at "there is a scooter 40 m away". The
last mile is the wall, and it is a harder wall than in-chat checkout because
the final step is physical rather than a form post.

## With skooti

`rake check:rideflow` runs the errand with no human account and no sign-in: the
assistant generates a keypair, proves possession, pays the Equihash
registration toll, reserves `SK-001`, signs the three AP2 mandates, pays, and
calls `start_rental`. The server checks three gates — the reservation is the
caller's and still held, the vehicle needs no licence, payment settled for this
reservation — and issues a short-lived Ed25519 rental token. A lock simulator
verifies it offline: domain-separation tag, signature against a baked-in public
key, scooter code, expiry, one-shot `jti`. No round-trip, no account session.

**The step the assistant does not take, and cannot** — a lock opens on a
Bluetooth write from something standing beside the scooter. An assistant
reaching this origin over HTTP has no radio, so it relays the token to its
human exactly as it relays a card-setup link. The human's tap on the NFC tag
launches the App Clip, and the clip writes the token to the lock.

A licence-free scooter needs no identity check at all. The signed KYC
attestation gates `rent_motorcycle` instead (`rake check:kyc`), where a licence
is the point.

## What an operator adds

The Kiosk gems and `rails g kiosk:install`; `config/routes/kiosk.rb`;
`app/controllers/kiosk/{fleet,rentals}_controller.rb`; a fleet Ed25519 keypair
whose public half is baked into every lock; the lock firmware (`firmware/`, an
ESP32-C3 reference) and the App Clip (`appclip/`, iOS only).

This is a demo against a fake operator with a stub PSP and a software lock
simulator; the firmware crypto is host-tested, and on-device Bluetooth is the
remaining hardware step.
