# frozen_string_literal: true

# Age-restricted flag for the alcohol product (KYC-DEMO-SCOPE decision (b):
# anonymized minimal KYC belongs on a LOW-liability eligibility gate where the
# transaction closes). A cart containing ANY age_restricted product requires the
# authenticated agent to carry an anonymized `age_over_18` attestation before
# create_order will accept it — the wine row is the only true value; every other
# grocery item stays false and needs no KYC.
class AddAgeRestrictedToProducts < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    add_column :products, :age_restricted, :boolean, null: false, default: false
  end
end
