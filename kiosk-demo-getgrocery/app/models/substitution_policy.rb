# frozen_string_literal: true
class SubstitutionPolicy < ApplicationRecord
  belongs_to :store
  belongs_to :out_product, class_name: "Product", foreign_key: :out_product_id
  belongs_to :suggested_product, class_name: "Product", foreign_key: :suggested_product_id
end
