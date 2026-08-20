# frozen_string_literal: true

# One grocery basket, its delivery window and its delivery address.
#
# `status` is a tiny lifecycle rather than a label, and every gate on this
# origin reads it: `created → paying → paid` is the per-order serialization the
# pay path claims through (see app/services/validating_payment_provider.rb — that claim
# is what makes a double capture impossible), and `scheduled`/`rescheduled` is
# where a delivery move leaves it.
class Order < ApplicationRecord
  # The five states this app ever writes, named once so a gate, a refusal
  # sentence and a wire row cannot come to disagree about their spelling.
  CREATED     = "created"
  PAYING      = "paying"
  PAID        = "paid"
  SCHEDULED   = "scheduled"
  RESCHEDULED = "rescheduled"

  # The states `create_order` will NOT swap the items of. `paying` is in this
  # list for a reason that is not tidiness: a /pay for the order is mid-flight
  # and its cart has already been checked against these items, so replacing them
  # under it is exactly the K-544 swap — pay for the cheap basket, receive the
  # expensive one.
  UNREPLACEABLE = [PAID, PAYING, SCHEDULED, RESCHEDULED].freeze

  # One reschedule per order; further changes go through the operator.
  ALREADY_SCHEDULED = [SCHEDULED, RESCHEDULED].freeze

  belongs_to :user
  has_many :order_items, dependent: :destroy

  # ── THE isolation predicate ────────────────────────────────────────────────
  # When getgrocery's handlers stopped writing SQL (K-654) this is the one
  # fragment that deliberately did NOT become a Ruby comparison, for the reason
  # the philslist pilot settled.
  #
  # `kiosk.current_user_id()` is a STABLE Postgres function reading the
  # transaction-local GUC `app.current_user_id`, which kiosk-server's
  # SessionContext sets with `SET LOCAL` — from the identity the wire resolved,
  # inside the very transaction the request runs in — and which evaporates at
  # COMMIT. A `where(user_id: <a ruby value>)` would be just as unforgeable
  # here; what it would cost is the part that generalises. Spec §7 makes
  # DB-enforced identity scoping a MUST, and this is the seam where the
  # app-layer predicate and the optional DB-layer RLS policy are literally the
  # same expression — which on THIS demo is not a hypothetical: `demo:rls` is
  # the fleet's only RLS enforcement proof and it applies its policies to this
  # very table.
  #
  # `Arel.sql` over a frozen literal rather than an interpolated string: there
  # is no caller-controlled value anywhere in this fragment. That is what makes
  # it exempt from the no-raw-SQL rule rather than an exception to it.
  scope :owned_by_current_principal, lambda {
    where(arel_table[:user_id].eq(Arel.sql("kiosk.current_user_id()")))
  }

  # The rows whose items `create_order` may still replace, and the rows
  # `reschedule_delivery` may still move. Written here because both verbs and
  # the pay path read the same lifecycle and must not each keep their own list.
  scope :replaceable,   -> { where.not(status: UNREPLACEABLE) }
  scope :reschedulable, -> { where.not(status: ALREADY_SCHEDULED) }

  # ── THE settled-cart containment, correlated to the row being selected ─────
  #
  # WHY THERE ARE TWO SPELLINGS OF ONE PREDICATE, and why this one is a frozen
  # SQL literal where {CartMandate.referencing} is Arel.
  #
  # {CartMandate.referencing} binds a SINGLE, CALLER-SUPPLIED order id, so the
  # value must be quoted by the adapter and the predicate is built as Arel
  # nodes. This one binds NO value at all: it correlates the cart's line_items
  # against `orders.id` — the column of whichever row the enclosing SELECT is
  # looking at — which is what lets `my_orders` and the back office answer
  # "paid?" for a whole LIST in one statement instead of one query per row.
  # There is nothing here for a caller to control, which is the same exemption
  # `owned_by_current_principal` above rests on: a frozen literal with no
  # interpolation is exempt from the no-raw-SQL rule rather than an exception to
  # it. Expressed as Arel it would be four nested NamedFunction nodes spelling
  # out CAST/json_build_array/json_build_object, and the one property that has
  # to survive this whole conversion — that the K-544/K-545 pay race is guarded
  # by EXACTLY this containment — would be harder to read, not easier.
  SETTLED_CART_REFERENCES_THIS_ROW = Arel.sql(
    "kiosk.cart_mandates.line_items @> " \
    "json_build_array(json_build_object('order_id', orders.id::text))::jsonb",
  ).freeze

  # ── THE seam the wire and the back office share ───────────────────────────
  # The settlements — OF THE RELATION THE CALLER IS ENTITLED TO SEE — whose cart
  # references the order row being selected.
  #
  # The parameter is the whole point. `my_orders` passes
  # `Settlement.of_current_principal`, so an assistant learns the paid state of
  # its OWN orders and nothing else; `Admin::OrdersController` passes
  # `Settlement.all`, because an operator's back office that could only see one
  # principal's settlements would show every order unpaid. The AUTHORITY differs
  # between the two surfaces and must; the CONTAINMENT must not, and this is the
  # one place it is written for both.
  #
  # @param settlements [ActiveRecord::Relation] settlements this caller may read
  def self.settling(settlements)
    settlements.joins(:cart_mandate)
               .where(SETTLED_CART_REFERENCES_THIS_ROW)
               .select(Arel.sql("1"))
  end

  # The `paid` flag `my_orders` publishes, as a SELECT-list expression.
  #
  # K-545: true when a settlement exists OR the order reached the terminal
  # `paid` state at capture. The order flips to `paid` the instant the charge
  # succeeds — a hair before the engine writes the settlement row — so honouring
  # the status closes the window where a lost pay response would otherwise read
  # paid=false and tempt a double-charging retry.
  def self.paid_flag(settlements)
    arel_table[:status].eq(PAID).or(settling(settlements).arel.exists)
  end

  # The currency a settled cart actually paid in, as a scalar subquery, or NULL
  # when the order is unpaid. The back office renders the glyph from it — a
  # non-EUR settlement would show its own symbol rather than a hardcoded €.
  def self.settled_currency(settlements)
    Arel::Nodes::Grouping.new(
      settlements.joins(:cart_mandate)
                 .where(SETTLED_CART_REFERENCES_THIS_ROW)
                 .select(Settlement.arel_table[:currency])
                 .limit(1)
                 .arel,
    )
  end
end
