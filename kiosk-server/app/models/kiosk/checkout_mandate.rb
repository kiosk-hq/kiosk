# frozen_string_literal: true

module Kiosk
  # The checkout mandate the engine records when it settles a `pay`: the line
  # items of the operator's checkout that the assistant agreed to pay for.
  # Read-only for the operator.
  class CheckoutMandate < Server::ApplicationRecord
    has_many :settlements, class_name: 'Kiosk::Settlement', dependent: nil, inverse_of: :checkout_mandate

    # Checkout mandates with a line item carrying these attributes, by jsonb
    # containment: `referencing(order_id: id)` matches `[{"order_id": id, "qty": 2}]`.
    # The values are quoted by the adapter, never interpolated.
    scope :referencing, lambda { |**attributes|
      where(Arel::Nodes::InfixOperation.new(
              '@>', arel_table[:line_items],
              Arel::Nodes.build_quoted([attributes.transform_values(&:to_s)].to_json)
            ))
    }
  end
end
