# kiosk-rls-minitest

Minitest integration for the [Kiosk](https://kiosk.tech) journey-test DSL.

## What it does

Connects the framework-agnostic journey-test DSL (`kiosk-test-support`) into Minitest. Adds:

- A convenience include — `include Kiosk::TestHelpers` mixes the journey helpers (`as_agent_of`, `as_user`, `as_agent`, `as_anonymous`, `query`, `run_query`, `run_action`, `pay_action`, `kiosk_seed`) and the assertions into a `Minitest::Test` subclass.
- Assertions: `assert_rls_denied { block }`, `assert_quota_exceeded { block }`, plus `refute_*` negative forms.
- Spec-DSL: `proc { ... }.must_raise_rls_denied`, etc.

## Install

```ruby
group :test do
  gem "kiosk-rls-minitest"
end
```

`require "kiosk/rls_minitest"` from your `test/test_helper.rb`.

## Configure an executor

The DSL is inert until an executor is configured. Configure the in-process executor, which runs against `kiosk-server` in your Rails app, in `test/test_helper.rb`:

```ruby
require "kiosk/rls_minitest"
require "kiosk/test_helpers/in_process_executor"

Kiosk::TestHelpers.executor = Kiosk::TestHelpers::InProcessExecutor.new
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
require "test_helper"

class OrdersTest < Minitest::Test
  include Kiosk::TestHelpers

  def setup
    super
    @alice = User.create!(email: "alice@example.com")
    @bob   = User.create!(email: "bob@example.com")
    kiosk_seed :orders, owner: @alice, item: "oranges"
    kiosk_seed :orders, owner: @bob,   item: "bread"
  end

  def test_shows_each_customer_only_their_own_orders
    as_agent_of(@alice) do
      assert_equal [{ item: "oranges" }], query("select item from orders")
    end
  end

  def test_refuses_an_order_written_for_another_customer
    as_agent_of(@bob) do
      assert_rls_denied { query("insert into orders (user_id, item) values ('#{@alice.id}', 'tea')") }
    end
  end
end
```

`test/kiosk/readme_example_test.rb` runs this block against Postgres.

## Status

Pre-v1.0 alpha: the DSL and the assertions may change between releases.

## License

Apache-2.0 — see `LICENSE.txt`.

## Links

- [kiosk.tech](https://kiosk.tech)
- [kiosk-test-support](https://github.com/kiosk-hq/kiosk/tree/main/kiosk-test-support) — shared DSL
- [kiosk-rls-rspec](https://github.com/kiosk-hq/kiosk/tree/main/kiosk-rls-rspec) — RSpec analogue
