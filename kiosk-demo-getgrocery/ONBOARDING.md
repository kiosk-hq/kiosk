# Merchant onboarding — 20 minutes to agent-ready

A step-by-step guide for adding Kiosk to an existing Rails app, based on
the [getgroceries](https://github.com/kiosk-hq/kiosk) demo provider.

If you have a working Rails + Postgres app with customers and products,
this guide gets you from zero to agent-ready in ~20 minutes.

---

## Step 1: Add the gems (2 min)

```ruby
# Gemfile
gem "kiosk-all", github: "kiosk-hq/kiosk"   # meta-gem: core + server + RLS + pay-stripe
```

```bash
bundle install
rails generate kiosk:install                # migration + initializer
rails db:migrate
```

---

## Step 2: Configure Kiosk (3 min)

`config/initializers/kiosk.rb`:

```ruby
Kiosk.configure do |c|
  c.user_model     = "User"          # your existing User model
  c.user_id_type   = :uuid           # or :integer
  c.user_id_column = :id

  c.issuer = ENV.fetch("KIOSK_ISSUER", "https://your-domain.com")
  c.roles  = %i[customer]
  c.owner  = { name: "Your Business", support: "help@your-domain.com" }

  # Stripe (test mode to start)
  c.payment_provider = Kiosk::PaymentProviders::Stripe.new(
    api_key: ENV["STRIPE_SECRET_KEY"],
    customer_resolver: ->(uid) { StripeCustomer.find_by(user_id: uid)&.customer_id },
    customer_saver:    ->(uid, cid) { StripeCustomer.create!(user_id: uid, customer_id: cid) },
  )
end
```

You need a `stripe_customers` table:

```ruby
# db/migrate/…_create_stripe_customers.rb
create_table :stripe_customers do |t|
  t.uuid   :user_id, null: false
  t.string :customer_id, null: false
  t.timestamps
end
add_index :stripe_customers, :user_id, unique: true
```

---

## Step 3: Mount the routes (1 min)

`config/routes.rb`:

```ruby
# Kiosk wire surface (6 REST endpoints + discovery)
get  "/.well-known/kiosk.json", to: "kiosk/server/well_known#show"
get  "/kiosk/schema",           to: "kiosk/server/exec#schema"
post "/kiosk/query",            to: "kiosk/server/exec#query"
post "/kiosk/run",              to: "kiosk/server/exec#run"
post "/kiosk/pay",              to: "kiosk/server/exec#pay"
post "/kiosk/agents/register",  to: "kiosk/server/agents_registration#create"
```

---

## Step 4: Register your queries (5 min)

Queries are read-only data access. Agents use them to browse your catalog.

`config/initializers/kiosk_queries.rb`:

```ruby
# What can the agent browse?
Kiosk::Server::Queries.register("catalog",
  description: "Browse in-stock products") do |_params|
  Product.where("stock > 0").select(:sku, :name, :price_cents).map(&:attributes)
end

# Delivery time slots
Kiosk::Server::Queries.register("delivery_slots",
  description: "Available delivery time slots for a given date",
  params: { date: "YYYY-MM-DD" }) do |params|
  date = Date.parse(params[:date])
  (8..20).step(2).map do |hour|
    { slot_at: Time.utc(date.year, date.month, date.day, hour, 0).iso8601,
      label: "#{hour}:00–#{hour + 2}:00" }
  end
end

# The agent can check its own orders
Kiosk::Server::Queries.register("my_orders",
  description: "List this customer's orders") do |_params|
  Order.where(user_id: ActiveRecord::Base.connection.execute(
    "SELECT kiosk.current_user_id()"
  ).first["uid"]).order(created_at: :desc).map(&:attributes)
end
```

---

## Step 5: Register your actions (5 min)

Actions mutate state — create orders, schedule delivery, set up payment.

`config/initializers/kiosk_actions.rb`:

```ruby
# Check/setup saved payment card
Kiosk::Server::Actions.register("payment_setup",
  description: "Check if the customer has a saved card on file",
  params: {}) do |_args|
  uid = current_user_id
  provider = Kiosk.configuration.payment_provider
  if provider.setup_required?(user_id: uid)
    { status: "setup_required", setup_url: provider.setup_url(user_id: uid) }
  else
    { status: "ready" }
  end
end

# Create an order
Kiosk::Server::Actions.register("create_order",
  description: "Create a new order",
  params: { items: "array of {sku, qty}" }) do |args|
  uid = current_user_id
  items = args[:items].map { |i| { sku: i[:sku], qty: i[:qty].to_i } }

  total_cents = items.sum do |item|
    Product.find_by!(sku: item[:sku]).price_cents * item[:qty]
  end

  order = Order.create!(user_id: uid, status: "created", total_cents: total_cents)
  items.each do |item|
    product = Product.find_by!(sku: item[:sku])
    order.order_items.create!(product: product, qty: item[:qty])
  end

  { order_id: order.id, total_cents: total_cents }
end

# Schedule delivery (requires payment to be settled first)
Kiosk::Server::Actions.register("schedule_delivery",
  description: "Schedule delivery for a paid order",
  params: { order_id: "uuid", delivery_slot_id: "integer", delivery_address: "string" },
  payment_gated: true) do |args|
  order = Order.find_by!(id: args[:order_id], user_id: current_user_id)
  slot_id = args[:delivery_slot_id].to_i

  hour = 8 + (slot_id - 1) * 2
  slot_at = Time.utc(Date.today.year, Date.today.month, Date.today.day + 1, hour, 0)

  order.update!(status: "scheduled", slot_at: slot_at, address: args[:delivery_address])
  { order_id: order.id, scheduled_at: slot_at.iso8601 }
end

def current_user_id
  ActiveRecord::Base.connection.execute(
    "SELECT kiosk.current_user_id() AS uid"
  ).first["uid"]
end
```

---

## Step 6: Seed some data (2 min)

```ruby
# db/seeds.rb
Product.create!(sku: "milk-1l",     name: "Whole Milk 1L",   price_cents: 199, stock: 50)
Product.create!(sku: "bread-ww",    name: "Whole Wheat Bread", price_cents: 299, stock: 30)
Product.create!(sku: "eggs-12",     name: "Free-Range Eggs 12-pack", price_cents: 449, stock: 20)
Product.create!(sku: "butter-250g", name: "Salted Butter 250g", price_cents: 349, stock: 15)
# … your actual product catalog

rails db:seed
```

---

## Step 7: Start the server and verify (2 min)

```bash
STRIPE_SECRET_KEY=sk_test_… rails s
```

Verify the discovery endpoint works:

```bash
curl http://localhost:3000/.well-known/kiosk.json | jq '.kiosk.issuer'
# => "http://localhost:3000"
```

Run the full flow:

```bash
bundle exec ruby getgrocery_flow.rb
# => {"http_register":201,"http_catalog":200,…, "pay":{"ok":true}}
```

---

## How agents find you (add 3 hooks, invisible to humans)

Agents need to discover that your site speaks Kiosk. Three hooks — two
machine-readable, one visual cue for the curious. None interfere with
your existing site.

### 1. HTML `<link>` tag (machine-readable)

Add to your `<head>`:

```html
<link rel="kiosk" href="https://kiosk.tech/skill.md">
```

An agent scanning the page sees this and knows it can transact here.

### 2. HTTP `Link` header (for agents that don't parse HTML)

In your controller:

```ruby
response.set_header("Link", '<https://kiosk.tech/skill.md>; rel="kiosk"')
```

A HEAD request is enough — no page download needed.

### 3. Visual "Agents — over here" card (human-readable, subtle)

Add a small section at the bottom of your homepage. It tells agent
users that your store speaks Kiosk without distracting regular customers:

```html
<section style="background:#0f2a1c;color:#fff;border-radius:16px;
                padding:26px 28px;max-width:880px;margin:8px auto 56px">
  <h2 style="font-size:19px">🤖 Agents — over here. This store speaks Kiosk.</h2>
  <p style="font-size:14px;opacity:.92">
    Your assistant can order and pay directly — no human account needed.
    Start at <code>/.well-known/kiosk.json</code>, then <code>/kiosk/help</code>.
  </p>
  <a href="/.well-known/kiosk.json">/.well-known/kiosk.json</a>
  <a href="/kiosk/help">/kiosk/help</a>
</section>
```

See [getgroceries' homepage](https://github.com/kiosk-hq/kiosk/blob/main/kiosk-demo-getgrocery/app/views/home/index.html.erb) for a live example — it's at the bottom, below the product categories. Regular users scroll past it. Agent users know where to look.

---

## What the agent experience looks like

From the agent's perspective, after these 7 steps:

1. **Discovery:** `GET /.well-known/kiosk.json` → finds your endpoint
2. **Registration:** generates RSA key, `POST /agents/register` → gets `access_token`
3. **Browse:** `POST /query {name:"catalog"}` → sees your products
4. **Order:** `POST /run {name:"create_order", …}` → order created
5. **Card setup:** `POST /run {name:"payment_setup"}` → human enters card once on Stripe
6. **Pay:** agent signs 3 JWS mandates, `POST /pay` → payment settled
7. **Schedule:** `POST /run {name:"schedule_delivery", …}` → delivery booked

The agent never sees your UI. It never creates an account for the user.
It transacts entirely through the REST surface you just added.

---

## What to do next

- **Test with your own agent.** Point Hermes (or any Kiosk-compatible agent) at your local server and say "order groceries."
- **Add more queries.** Expose anything an agent might need — store locations, nutritional info, allergy filters.
- **Add more actions.** Reservations, cancellations, loyalty points — anything your app does today.
- **Go to production.** Swap `STRIPE_SECRET_KEY` for a live key, add your domain to `KIOSK_ISSUER`, and deploy.

---

## Reference

- [kiosk.tech](https://kiosk.tech) — landing page + agent skill
- [kiosk.tech/skill.md](https://kiosk.tech/skill.md) — the universal agent skill
- [github.com/kiosk-hq/kiosk](https://github.com/kiosk-hq/kiosk) — OSS reference implementation
- `getgrocery_flow.rb` — full agent walkthrough in this demo
- `bin/demo` — `rake demo` runner with curl output
