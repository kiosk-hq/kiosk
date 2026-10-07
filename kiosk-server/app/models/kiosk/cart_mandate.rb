# frozen_string_literal: true

module Kiosk
  # The signed cart the engine records when it settles a `pay`: the line items
  # the assistant agreed to pay for. Read-only for the operator.
  class CartMandate < ::ActiveRecord::Base
    self.table_name = "#{Kiosk.configuration.schema}.cart_mandates"

    has_many :settlements, class_name: "Kiosk::Settlement", dependent: nil, inverse_of: :cart_mandate

    # Carts with a line item carrying these attributes, by jsonb containment:
    # `referencing(order_id: id)` matches `[{"order_id": id, "qty": 2}]`. The
    # values are quoted by the adapter, never interpolated.
    scope :referencing, lambda { |**attributes|
      where(Arel::Nodes::InfixOperation.new(
        "@>", arel_table[:line_items],
        Arel::Nodes.build_quoted([attributes.transform_values(&:to_s)].to_json),
      ))
    }
  end
end
