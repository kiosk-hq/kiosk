# kiosk-rls-rspec

RSpec integration for the [Kiosk](https://kiosk.tech) journey-test DSL.

## What it does

Connects the framework-agnostic journey-test DSL (`kiosk-test-support`) into RSpec. Adds:

- `type: :kiosk_journey` metadata — auto-includes the journey helpers (`as_agent_of`, `as_user`, `as_agent`, `as_anonymous`, `query`, `run_query`, `run_action`, `pay_action`, `kiosk_seed`).
- Matchers: `be_rls_denied`, `be_quota_exceeded`.

## Install

```ruby
group :test do
  gem "kiosk-rls-rspec"
end
```

`require "kiosk/rls_rspec"` from your `spec_helper.rb`. The integration registers automatically when RSpec is already loaded.

## Configure an executor

The DSL is inert until an executor is configured. Configure the in-process executor, which runs against `kiosk-server` in your Rails app, in `spec/spec_helper.rb`:

```ruby
require "kiosk/rls_rspec"
require "kiosk/test_helpers/in_process_executor"

RSpec.configure do |config|
  config.before(:suite) do
    Kiosk::TestHelpers.executor = Kiosk::TestHelpers::InProcessExecutor.new
  end
end
```

For unit-shaped tests that need no live database, use the bundled `NullExecutor` instead:

```ruby
Kiosk::TestHelpers.executor = Kiosk::TestHelpers::NullExecutor.new
```

## Example

The example needs an `orders` table whose policy shows a customer only the rows
with their own `user_id`, and `c.enforce_db_role`, so that each scope runs as
`c.app_role` (see the kiosk-rls README). Each `as_*` scope runs in a
transaction that rolls back. `kiosk_seed` writes outside the scopes, so a test
reads the rows that it seeds:

```ruby
RSpec.describe "orders", type: :kiosk_journey do
  let(:alice) { User.create!(email: "alice@example.com") }
  let(:bob)   { User.create!(email: "bob@example.com") }

  before do
    kiosk_seed :orders, owner: alice, item: "oranges"
    kiosk_seed :orders, owner: bob,   item: "bread"
  end

  it "shows each customer only their own orders" do
    as_agent_of(alice) do
      expect(query("select item from orders")).to contain_exactly({ item: "oranges" })
    end
  end

  it "refuses an order written for another customer" do
    as_agent_of(bob) do
      expect { query("insert into orders (user_id, item) values ('#{alice.id}', 'tea')") }.to be_rls_denied
    end
  end
end
```

`spec/kiosk/readme_example_spec.rb` runs this block against Postgres.

## Status

Pre-v1.0 alpha: the DSL and the matchers may change between releases.

## License

Apache-2.0 — see `LICENSE.txt`.

## Links

- [kiosk.tech](https://kiosk.tech)
- [kiosk-test-support](https://github.com/kiosk-hq/kiosk/tree/main/kiosk-test-support) — shared DSL
- [kiosk-rls-minitest](https://github.com/kiosk-hq/kiosk/tree/main/kiosk-rls-minitest) — Minitest analogue
