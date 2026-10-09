# kiosk-test-support

Test helpers for [Kiosk](https://kiosk.tech) origins, and the journey-test DSL of the Kiosk test harnesses.

## What it does

- `Kiosk::TestHelpers::Assistant` — registers, pays tolls, queries, runs actions, pays and listens for events against an origin, as an AI assistant does.
- `Kiosk::TestHelpers::Wire` — the same transport without a principal: any method, any path, any headers.
- `Kiosk::StoryTest` / `Kiosk::TestHelpers::Story` — a test told as a business story by customers' assistants and the people on the operator's site.
- `Kiosk::TestHelpers::Kyc` — stands in for the operator's KYC provider, so a test decides how an identity check ends.
- `Kiosk::TestHelpers::StripeMock` — starts a local stripe-mock that answers a confirmed charge as paid.
- `Kiosk::TestHelpers::LiveServer` — serves the app over HTTP from the test process and gives the test an assistant for it.
- `Kiosk::TestHelpers::SeededDatabase` — each test starts from the seeds and leaves the database empty.
- `Kiosk::TestHelpers::DescriptorExamples` — the examples a served `/kiosk/schema` publishes, each checked against its schema.

Carries the shared pieces of the Kiosk journey-test DSL: the `Journey` module mixed into RSpec / Minitest tests, the pluggable `executor` contract, a `NullExecutor` for self-tests, and the structured error classes that the framework-specific matchers and assertions look for.

The journey DSL comes with one of the harnesses:

> **Not on RubyGems yet** — so every `gem` line below carries `github: "kiosk-hq/kiosk"`, which is what makes it copy-pasteable today. Publication status and the canonical install are stated once, in the monorepo README's [Install](https://github.com/kiosk-hq/kiosk#install) section.

```ruby
group :test do
  gem "kiosk-rls-rspec", github: "kiosk-hq/kiosk"       # RSpec
  # or
  gem "kiosk-rls-minitest", github: "kiosk-hq/kiosk"    # Minitest
end
```

Both harnesses pull `kiosk-test-support` as a transitive dependency.

## DSL

```ruby
as_agent_of(alice) do
  run_action :create_order, items: ["bread"]
end

as_user(alice) do
  expect(query("select item from orders")).to contain_exactly("bread")
end

as_anonymous do
  expect { query("select * from orders") }.to be_rls_denied
end
```

Helpers: `as_agent_of(user, role:)`, `as_user(user, role:)`, `as_agent(name)`, `as_anonymous`, `query(sql)`, `run_query(name, **args)`, `run_action(name, **args)`, `pay_action(name, **args)`, `kiosk_seed(table, count:, owner:, **attrs)`. See the `Kiosk::TestHelpers::Journey` docstrings for full semantics.

## Wiring an executor

The DSL is inert until you wire an executor. In production-shaped tests you wire `Kiosk::Server::TestExecutor` (ships with `kiosk-server`):

```ruby
# spec/spec_helper.rb (RSpec) or test/test_helper.rb (Minitest)
require "kiosk/server/test_executor"
Kiosk::TestHelpers.executor = Kiosk::Server::TestExecutor.new
```

For unit-shaped tests where you only care about call ordering, use the bundled `NullExecutor`:

```ruby
Kiosk::TestHelpers.executor = Kiosk::TestHelpers::NullExecutor.new.tap do |e|
  e.enqueue_query [{ "item" => "bread" }]
end
```

The `NullExecutor` is the zero-dependency fallback for unit-shaped tests; production-shaped tests wire `Kiosk::Server::TestExecutor` from the shipped `kiosk-server` gem (above).

## Driving the wire as an assistant

`Kiosk::TestHelpers::Assistant` registers, pays proof-of-work tolls, queries, runs, pays with signed mandates and listens on `<endpoint>/events`, against any origin — a test's own live server or a deployment:

```ruby
require "kiosk/test_helpers/assistant"

assistant = Kiosk::TestHelpers::Assistant.new(base_url: live_url)
rider     = assistant.register!
events    = assistant.events(rider)
events.subscribe("kyc_verification")
assistant.run(rider, name: "reserve", scooter_code: "SK-001")
```

Every answer carries its status, parsed body and headers. `Kiosk::TestHelpers::Wire` is the same transport without a principal: any method, any path, any headers.

## Telling a business story

`Kiosk::StoryTest` (Minitest), or `require "kiosk/story_spec"` and `type: :story` (RSpec), serves the app from the test process and tells a story through `Customer`s, which a demo subclasses with its own business actions:

```ruby
class Shopper < Kiosk::TestHelpers::Customer
  def orders(*skus) = does(:create_order, items: skus.map { { sku: _1, qty: 1 } })
  def pays_for(order) = pays(total: order["total_cents"], scope: "grocery", line_items: [{ order_id: order["order_id"] }])
end

class ShopStory < Kiosk::StoryTest
  test "a shopper orders and pays" do
    shopper = a_customer(as: Shopper)
    assert shopper.pays_for(shopper.orders("banana")).ok?
  end
end
```

- `a_customer(as:)` registers an assistant; `a_newcomer(as:)` holds a key and no account yet; `published(path)` reads what the origin shows anyone.
- `Customer#asks` and `#does` answer an `Answer` (`ok?`, `refused?(code)`, `detail`, `hint`, `rows`, `header`, `tolls_paid`, `solved_toll`, `next_page`); `asks(…, unpaid: true)` or `asks(…, proofs: […])` leaves the toll to the story.
- `Customer#sets_up_payment` and `#requests_verification` run the engine's `payment_setup` and `request_kyc`, and `#hears_verification_passed(check)` waits for that check's outcome; `#pays(total:, scope:, line_items:, currency:)` signs the intent, cart and payment mandates for a quote.
- `Customer#account`, `#role` and `#claims` read its credential; `#signs_back_in`, `#with_a_fresh_credential`, `#redeems(link_code)`, `#asks_to_be_linked`, `#polls` and `#collects` are the sign-in and linking ceremonies.
- `Customer#listens_for`, `#follows(*topics, subject:, since:)` and `#hears(topic, about:, on:, **data)` read the event stream, holding each heard payload to the schema the origin publishes for its topic.
- `a_person(email:, password:)` signs a person in on the operator's site through `kiosk-user-idp-devise`'s `DeviseSession`: `links(customer)`, `link_code`, `approves(user_code)`, `unlinks(customer)`, `visits(path)`.

## Identity checks in tests

A real identity check is a human showing documents to a provider; a test cannot do that, so `Kiosk::TestHelpers::Kyc` stands in for the operator's KYC provider for the length of each test and the test says how the check ends. The engine receives the provider's callback and runs the operator's code exactly as it would in production:

```ruby
require "kiosk/test_helpers/kyc"

class LicenceStory < Kiosk::StoryTest   # or an RSpec group including Kiosk::TestHelpers::Story
  include Kiosk::TestHelpers::Kyc

  test "a motorcycle opens once the licence check passes" do
    rider = a_customer
    check = rider.requests_verification
    the_verification_service_confirms(check, age_over_18: true, licence_a: true)
    assert rider.hears_verification_passed(check)
  end
end
```

`kyc_attestation(principal, **attributes)` signs an attestation an assistant submits to `POST <endpoint>/agents/kyc`. A check the human refuses sends nothing, so there is no helper for it.

`Kiosk::TestHelpers::StripeMock.start` fronts a local [stripe-mock](https://github.com/stripe/stripe-mock) that answers a confirmed charge as paid.

## Status

Pre-v1.0 alpha. The Journey DSL surface is stable across pre-v1.0 minor bumps; the executor contract may still evolve pre-v1.0 (`kiosk-server` ships `Kiosk::Server::TestExecutor` against it today).

## License

Apache-2.0 — see `LICENSE.txt`.

## Links

- [kiosk.tech](https://kiosk.tech)
- [Issue tracker](https://github.com/kiosk-hq/kiosk/issues)
