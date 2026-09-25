# Before and after — grocery delivery

**For an operator weighing adoption:** what an AI assistant cannot do at a
grocery platform today, and what the same errand looks like once this demo's
wire is installed. The code is in this directory; this is the argument.

**Honesty note up front.** getgrocery is what Instacart or Getir would look
like if it spoke Kiosk — a fake-but-realistic operator built to show the
mechanism. Nothing here implies either works this way.

## Today

Every current personal AI assistant stalls at the same walls: the anti-bot
screen, the login gate, and — uniquely in grocery — the substitution
confirmation wall. Behavioural fingerprinting flags assistant traffic; OTP
walls assume a human-held device; the card lives outside the assistant's
context; and PSD2 SCA needs a challenge only the human can answer. Documented
ChatGPT-Agent food orders take 6–20 minutes, two to three times a human, and
stop at the anti-bot screen, login or payment.

Both flagship consumer-commerce connectors in Claude today, Uber Eats and
Booking.com, stop at discovery: the terminal step is a deep link back to the
operator's own app, where the human registers and pays.

The ceiling is economic, not technical. Grocery retail media needs an
authenticated in-app session for sponsored placement and attribution, and a
silent order through an API erases that ad surface. The discovery funnel is the
product.

## With getgrocery

`rake check:shop` runs the errand end to end: the assistant registers itself
under the toll, reads `catalog` and `delivery_slots`, calls `create_order` with
a slot and an in-zone address, and pays. The catalog returns in-stock items
only, so the assistant resolves substitutions by reasoning over it — no
operator-side substitution surface, and no push notification for a human to
answer.

**The human is needed once.** A card has to reach the operator: `payment_setup`
returns a URL the assistant relays for its human to open. After that, repeat
orders settle off-session with no taps. The scripted run skips that step with
`KIOSK_TEST_AUTOCARD=1` so it runs unattended; a production flow cannot.

To watch an assistant drive it rather than a script, see "Watch it work" in
`README.md`.

## What an operator adds

The Kiosk gems in `Gemfile`, then one command:

<!-- derived: generator | from: kiosk-server/lib/generators/kiosk/install/install_generator.rb | why: the one command an adopter types, held to the namespace that generator answers -->
```
rails g kiosk:install
```

It writes `config/initializers/kiosk.rb` and the `kiosk.*` migrations. What is
left is read in the directory rather than quoted here:
`config/routes/kiosk.rb`, the engine mounted in one line and then one route per
verb — GET for a query, POST for an action — and
`app/controllers/kiosk/{storefront,orders}_controller.rb`, the verbs as
ordinary Rails controllers. The toll, the cashier check and the Stripe adapter
are the initializer's.

No new human-facing login, no ceded customer relationship, no change to the
site humans use.
